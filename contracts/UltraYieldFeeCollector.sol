// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CuratedFeeCollectorBase} from "./CuratedFeeCollectorBase.sol";
import {IUltraVault7540} from "./interfaces/IUltraVault7540.sol";

/// @title UltraYieldFeeCollector
/// @notice Partner fee layer for UltraYield's ASYNCHRONOUS ERC-7540 vault. The collector is the single
///         controller/owner of the async-redeem queue. Exit is two-step: `requestRedeem` then (after the
///         operator fulfills on the underlying) `claim`. Withdrawal + AUM fees are charged at claim (AUM
///         accrues from the position's start block through to claim). Both the user and the partner can
///         request and claim; assets go to the user, fees to the partner.
contract UltraYieldFeeCollector is CuratedFeeCollectorBase {
    using SafeERC20 for IERC20;

    struct Pending {
        uint256 shares;
        uint256 lastBlock; // AUM start block carried from the position at request time
    }

    mapping(address => Pending) public pending;
    uint256 public totalPending;

    event RedeemRequested(address indexed user, address indexed caller, uint256 shares, uint256 requestId);

    error NothingToClaim();

    constructor(
        IERC4626 _underlying,
        address _owner,
        address _partner,
        uint16 _depositFeeBps,
        uint16 _withdrawalFeeBps,
        uint256 _aumFeePerBlock
    ) CuratedFeeCollectorBase(_underlying, _owner, _partner, _depositFeeBps, _withdrawalFeeBps, _aumFeePerBlock) {
        // On requestRedeem the vault pulls the collector's shares via _spendAllowance(owner, vault),
        // so pre-approve the vault (the share token IS the vault) to move the collector's shares.
        IERC20(address(_underlying)).forceApprove(address(_underlying), type(uint256).max);
    }

    function _v() private view returns (IUltraVault7540) {
        return IUltraVault7540(address(underlying));
    }

    // --------------------------------------------------------------------
    // Request (user or partner)
    // --------------------------------------------------------------------

    function requestRedeem(uint256 shares) external nonReentrant returns (uint256 requestId) {
        return _request(msg.sender, shares);
    }

    function requestRedeemAll() external nonReentrant returns (uint256 requestId) {
        return _request(msg.sender, _positions[msg.sender].shares);
    }

    function requestRedeemFor(address user, uint256 shares) external nonReentrant returns (uint256 requestId) {
        _onlyPartner();
        return _request(user, shares);
    }

    function requestRedeemAllFor(address user) external nonReentrant returns (uint256 requestId) {
        _onlyPartner();
        return _request(user, _positions[user].shares);
    }

    function _request(address user, uint256 shares) internal returns (uint256 requestId) {
        if (shares == 0) revert ZeroAmount();
        Position storage p = _positions[user];
        if (shares > p.shares) revert InsufficientShares();

        Pending storage pe = pending[user];
        // Carry the AUM start block into the pending parcel (share-weighted across multiple requests).
        if (pe.shares == 0) {
            pe.lastBlock = p.lastBlock;
        } else {
            pe.lastBlock = (pe.shares * pe.lastBlock + shares * p.lastBlock) / (pe.shares + shares);
        }

        p.shares -= shares;
        totalShares -= shares;
        pe.shares += shares;
        totalPending += shares;

        requestId = _v().requestRedeem(shares, address(this), address(this));
        emit RedeemRequested(user, msg.sender, shares, requestId);
    }

    // --------------------------------------------------------------------
    // Claim (user or partner) — fees charged here; assets to the user
    // --------------------------------------------------------------------

    function claim() external nonReentrant returns (uint256 net) {
        return _claim(msg.sender);
    }

    function claimFor(address user) external nonReentrant returns (uint256 net) {
        _onlyPartner();
        return _claim(user);
    }

    function _claim(address user) internal returns (uint256 net) {
        Pending storage pe = pending[user];
        uint256 ps = pe.shares;
        if (ps == 0) revert ZeroAmount();

        uint256 claimable = _v().maxRedeem(address(this));
        uint256 toClaim = ps < claimable ? ps : claimable;
        if (toClaim == 0) revert NothingToClaim();

        uint256 lastBlock = pe.lastBlock;
        uint256 assetsGross = _v().redeem(toClaim, address(this), address(this));

        pe.shares = ps - toClaim;
        totalPending -= toClaim;

        return _chargeAndPay(user, msg.sender, toClaim, assetsGross, lastBlock);
    }
}
