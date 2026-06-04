// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CuratedFeeCollectorBase} from "./CuratedFeeCollectorBase.sol";
import {HwmFeeMath} from "./libraries/HwmFeeMath.sol";
import {IUltraVault7540} from "./interfaces/IUltraVault7540.sol";

/// @title UltraYieldFeeCollector
/// @notice Per-user HWM fee layer for UltraYield's *asynchronous* ERC-7540 vault. The collector is the
///         single `controller`/`owner` of the underlying async-redeem queue and keeps an internal
///         per-user pending ledger. The performance fee is crystallized (locked) at `requestRedeem`
///         time; only the withdrawal fee is applied at `claim`.
contract UltraYieldFeeCollector is CuratedFeeCollectorBase {
    using SafeERC20 for IERC20;

    /// @notice Per-user shares that have been requested for redemption (perf-fee already settled).
    mapping(address => uint256) public pendingShares;
    /// @notice Aggregate user pending shares submitted to the underlying queue.
    uint256 public totalPendingShares;
    /// @notice Perf-fee shares requested for collection, awaiting fulfillment.
    uint256 public feePendingShares;

    event RedeemRequested(address indexed user, uint256 shares, uint256 requestId);
    event Claimed(
        address indexed user, address indexed receiver, uint256 shares, uint256 assetsGross, uint256 withdrawFee, uint256 netOut
    );
    event RequestCancelled(address indexed user, uint256 shares);
    event FeeRedeemRequested(uint256 feeShares);
    event FeesClaimedAsync(uint256 feeShares, uint256 assetsToRecipient);

    error NothingToClaim();
    error UseAsyncFeeCollection();
    error FulfillmentStarted();

    constructor(
        IERC4626 _underlying,
        address _owner,
        address _feeRecipient,
        uint16 _depositFeeBps,
        uint16 _withdrawFeeBps,
        uint16 _perfFeeBps
    ) CuratedFeeCollectorBase(_underlying, _owner, _feeRecipient, _depositFeeBps, _withdrawFeeBps, _perfFeeBps) {
        // The collector is the ERC-7540 owner/controller; on requestRedeem the vault pulls the
        // collector's shares via _spendAllowance(owner, vault), so pre-approve the vault (the share
        // token IS the vault) to move the collector's shares.
        IERC20(address(_underlying)).forceApprove(address(_underlying), type(uint256).max);
    }

    function _v() private view returns (IUltraVault7540) {
        return IUltraVault7540(address(underlying));
    }

    // ----------------------------------------------------------------
    // Async exit: request -> (operator fulfills on the underlying) -> claim
    // ----------------------------------------------------------------

    /// @notice Request redemption of `shares` of the caller's position.
    /// @dev    Crystallizes the per-user performance fee at the current ratio (locking it), then
    ///         moves the shares into the caller's pending bucket and submits to the underlying queue.
    function requestRedeem(uint256 shares) external nonReentrant returns (uint256 requestId) {
        if (shares == 0) revert ZeroAmount();

        _crystallize(msg.sender); // lock perf fee at request-time ratio

        Position storage p = _positions[msg.sender];
        if (shares > p.shares) revert InsufficientShares();

        p.shares -= shares;
        totalUserShares -= shares;
        pendingShares[msg.sender] += shares;
        totalPendingShares += shares;

        requestId = _v().requestRedeem(shares, address(this), address(this));
        emit RedeemRequested(msg.sender, shares, requestId);
    }

    /// @notice Request redemption of the caller's entire position (handles the post-crystallization
    ///         balance, so callers don't need to predict the skimmed fee shares).
    function requestRedeemAll() external nonReentrant returns (uint256 requestId) {
        _crystallize(msg.sender);
        Position storage p = _positions[msg.sender];
        uint256 shares = p.shares;
        if (shares == 0) revert InsufficientShares();

        p.shares = 0;
        totalUserShares -= shares;
        pendingShares[msg.sender] += shares;
        totalPendingShares += shares;

        requestId = _v().requestRedeem(shares, address(this), address(this));
        emit RedeemRequested(msg.sender, shares, requestId);
    }

    /// @notice Claim fulfilled redemption(s) for the caller. Applies the withdrawal fee; no further
    ///         performance fee (already locked at request). Supports partial fulfillment.
    function claim(address receiver) external nonReentrant returns (uint256 netOut) {
        if (receiver == address(0)) revert ZeroAddress();
        uint256 userPending = pendingShares[msg.sender];
        if (userPending == 0) revert ZeroAmount();

        uint256 claimable = _v().maxRedeem(address(this));
        uint256 toClaim = userPending < claimable ? userPending : claimable;
        if (toClaim == 0) revert NothingToClaim();

        uint256 assetsGross = _v().redeem(toClaim, address(this), address(this));

        pendingShares[msg.sender] = userPending - toClaim;
        totalPendingShares -= toClaim;

        (uint256 wdFee, uint256 net) = HwmFeeMath.splitFeeUp(assetsGross, withdrawFeeBps);
        if (wdFee != 0) asset.safeTransfer(feeRecipient, wdFee);
        asset.safeTransfer(receiver, net);
        netOut = net;

        emit Claimed(msg.sender, receiver, toClaim, assetsGross, wdFee, net);
    }

    /// @notice Cancel the caller's outstanding request (only before any fulfillment has begun).
    /// @dev    Cancels the whole controller queue at the underlying and re-requests the remainder
    ///         (other users' + fee pending). Restores the caller's shares to their position.
    function cancelRequest() external nonReentrant {
        uint256 userPending = pendingShares[msg.sender];
        if (userPending == 0) revert ZeroAmount();
        if (_v().maxRedeem(address(this)) != 0) revert FulfillmentStarted();

        _v().cancelRedeemRequest(address(this));
        uint256 remaining = totalPendingShares + feePendingShares - userPending;
        if (remaining != 0) _v().requestRedeem(remaining, address(this), address(this));

        totalPendingShares -= userPending;
        pendingShares[msg.sender] = 0;

        Position storage p = _positions[msg.sender];
        p.shares += userPending;
        totalUserShares += userPending;

        emit RequestCancelled(msg.sender, userPending);
    }

    // ----------------------------------------------------------------
    // Async fee collection (two-step)
    // ----------------------------------------------------------------

    /// @inheritdoc CuratedFeeCollectorBase
    /// @dev Synchronous collection is impossible for an async underlying; use the two-step flow.
    function collectFees() external view override returns (uint256) {
        revert UseAsyncFeeCollection();
    }

    /// @notice Step 1: request redemption of the accrued performance-fee shares.
    function requestCollectFees() external nonReentrant {
        _onlyFeeAuthority();
        uint256 fs = accruedFeeShares;
        if (fs == 0) revert NothingToCollect();
        accruedFeeShares = 0;
        feePendingShares += fs;
        _v().requestRedeem(fs, address(this), address(this));
        emit FeeRedeemRequested(fs);
    }

    /// @notice Step 2: after fulfillment, redeem the fee shares to `feeRecipient`.
    function claimFees() external nonReentrant returns (uint256 assetsOut) {
        _onlyFeeAuthority();
        uint256 fp = feePendingShares;
        if (fp == 0) revert NothingToCollect();
        uint256 claimable = _v().maxRedeem(address(this));
        uint256 toClaim = fp < claimable ? fp : claimable;
        if (toClaim == 0) revert NothingToClaim();
        assetsOut = _v().redeem(toClaim, feeRecipient, address(this));
        feePendingShares = fp - toClaim;
        emit FeesClaimedAsync(toClaim, assetsOut);
    }
}
