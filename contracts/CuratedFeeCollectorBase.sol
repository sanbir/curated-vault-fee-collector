// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {HwmFeeMath} from "./libraries/HwmFeeMath.sol";

/// @title CuratedFeeCollectorBase
/// @notice Shared machinery for the P2P fee layer that sits on top of a curated ERC-4626 vault and
///         charges end users a deposit fee, a withdrawal fee, and a *per-user high-water-mark*
///         performance fee (NOT socialized). One collector instance wraps one underlying vault.
/// @dev    Custody-only: users never hold the underlying shares; the collector custodies them and
///         credits each user a NON-TRANSFERABLE internal `Position`. Concrete subclasses implement
///         the exit path (synchronous redeem vs. ERC-7540 async request/claim).
abstract contract CuratedFeeCollectorBase is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using HwmFeeMath for uint256;

    // --- fee caps (BPS) ---
    uint16 public constant MAX_DEPOSIT_FEE = 500; // 5%
    uint16 public constant MAX_WITHDRAWAL_FEE = 200; // 2%
    uint16 public constant MAX_PERFORMANCE_FEE = 3000; // 30%

    // --- immutables ---
    IERC4626 public immutable underlying;
    IERC20 public immutable asset;
    uint256 public immutable SHARE_UNIT; // 10**underlyingShareDecimals

    // --- config ---
    uint16 public depositFeeBps;
    uint16 public withdrawFeeBps;
    uint16 public perfFeeBps;
    address public feeRecipient;

    // --- per-user position (non-transferable) ---
    struct Position {
        uint256 shares; // underlying shares attributed to the user (held by this collector)
        uint256 hwm; // high-water price: asset units per whole share, at last crystallization
    }

    mapping(address => Position) internal _positions;

    /// @notice Underlying shares skimmed as performance fee, awaiting collection by `feeRecipient`.
    uint256 public accruedFeeShares;
    /// @notice Sum of all users' position shares (excludes `accruedFeeShares`).
    uint256 public totalUserShares;

    // --- events ---
    event Deposited(
        address indexed user, uint256 assetsIn, uint256 depositFee, uint256 netDeposited, uint256 sharesMinted, uint256 hwm
    );
    event PerformanceFeeCrystallized(
        address indexed user, uint256 feeShares, uint256 feeAssets, uint256 atRatio
    );
    event WithdrawalProcessed(
        address indexed user, address indexed receiver, uint256 sharesRedeemed, uint256 assetsGross, uint256 withdrawFee, uint256 netOut
    );
    event FeesCollected(uint256 feeShares, uint256 assetsToRecipient);
    event FeesSet(uint16 depositFeeBps, uint16 withdrawFeeBps, uint16 perfFeeBps);
    event FeeRecipientSet(address indexed feeRecipient);

    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh();
    error InsufficientShares();
    error NotFeeAuthority();
    error NothingToCollect();

    constructor(
        IERC4626 _underlying,
        address _owner,
        address _feeRecipient,
        uint16 _depositFeeBps,
        uint16 _withdrawFeeBps,
        uint16 _perfFeeBps
    ) Ownable(_owner) {
        if (address(_underlying) == address(0) || _feeRecipient == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }
        underlying = _underlying;
        asset = IERC20(_underlying.asset());
        SHARE_UNIT = 10 ** IERC20Metadata(address(_underlying)).decimals();
        feeRecipient = _feeRecipient;
        _setFees(_depositFeeBps, _withdrawFeeBps, _perfFeeBps);
        IERC20(_underlying.asset()).forceApprove(address(_underlying), type(uint256).max);
    }

    // ----------------------------------------------------------------
    // Deposit (synchronous for both UltraYield and Fluid Lite)
    // ----------------------------------------------------------------

    /// @notice Deposit `assets` of the underlying asset; mints a position for `receiver`.
    /// @dev    Charges the deposit fee in asset, crystallizes any pending perf fee on the existing
    ///         position FIRST (so new capital cannot dilute the mark), then deposits the remainder.
    function deposit(uint256 assets, address receiver) external nonReentrant whenNotPaused returns (uint256 sharesMinted) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        asset.safeTransferFrom(msg.sender, address(this), assets);

        (uint256 depFee, uint256 net) = HwmFeeMath.splitFeeUp(assets, depositFeeBps);
        if (depFee != 0) asset.safeTransfer(feeRecipient, depFee);

        // Crystallize the existing position (no-op for a fresh position) and obtain the entry ratio.
        uint256 curRatio = _crystallize(receiver);

        sharesMinted = underlying.deposit(net, address(this));

        Position storage p = _positions[receiver];
        p.shares += sharesMinted;
        totalUserShares += sharesMinted;
        // Ratchet / initialize the mark to the entry ratio.
        if (curRatio > p.hwm) p.hwm = curRatio;

        emit Deposited(receiver, assets, depFee, net, sharesMinted, p.hwm);
    }

    // ----------------------------------------------------------------
    // Performance-fee crystallization (per user, NOT socialized)
    // ----------------------------------------------------------------

    /// @dev Skims the performance fee owed on `user`'s position into `accruedFeeShares` and ratchets
    ///      the position's HWM up to the current ratio. Returns the current ratio.
    function _crystallize(address user) internal returns (uint256 curRatio) {
        curRatio = _currentRatio();
        Position storage p = _positions[user];
        uint256 shares = p.shares;
        if (shares != 0 && curRatio > p.hwm) {
            uint256 feeAssets = HwmFeeMath.perfFeeAssets(shares, p.hwm, curRatio, SHARE_UNIT, perfFeeBps);
            uint256 feeShares = HwmFeeMath.assetsToSharesUp(feeAssets, curRatio, SHARE_UNIT);
            if (feeShares > shares) feeShares = shares; // safety clamp
            if (feeShares != 0) {
                p.shares = shares - feeShares;
                totalUserShares -= feeShares;
                accruedFeeShares += feeShares;
                emit PerformanceFeeCrystallized(user, feeShares, feeAssets, curRatio);
            }
        }
        if (curRatio > p.hwm) p.hwm = curRatio;
    }

    /// @dev Current price-per-share: asset base-units per one whole underlying share.
    function _currentRatio() internal view returns (uint256) {
        return underlying.convertToAssets(SHARE_UNIT);
    }

    /// @notice Operator-triggered crystallization of a user's accrued performance fee (P2P "poke").
    /// @dev    Realizes the fee at the current ratio and ratchets the user's HWM. Fee-authority only
    ///         (so a third party cannot lock in a fee at an adversarially-chosen moment).
    function crystallize(address user) external nonReentrant {
        _onlyFeeAuthority();
        _crystallize(user);
    }

    // ----------------------------------------------------------------
    // Fee collection
    // ----------------------------------------------------------------

    /// @notice Redeem the accrued performance-fee shares to `feeRecipient`.
    /// @dev    Sync collectors redeem immediately; async collectors override (request/claim).
    function collectFees() external virtual nonReentrant returns (uint256 assetsOut) {
        _onlyFeeAuthority();
        uint256 fs = accruedFeeShares;
        if (fs == 0) revert NothingToCollect();
        accruedFeeShares = 0;
        assetsOut = underlying.redeem(fs, feeRecipient, address(this));
        emit FeesCollected(fs, assetsOut);
    }

    // ----------------------------------------------------------------
    // Admin
    // ----------------------------------------------------------------

    function setFees(uint16 _depositFeeBps, uint16 _withdrawFeeBps, uint16 _perfFeeBps) external onlyOwner {
        _setFees(_depositFeeBps, _withdrawFeeBps, _perfFeeBps);
    }

    function _setFees(uint16 _depositFeeBps, uint16 _withdrawFeeBps, uint16 _perfFeeBps) internal {
        // Caps enforced on the NEW value (avoids the iETHv2 old-value-check bug).
        if (
            _depositFeeBps > MAX_DEPOSIT_FEE || _withdrawFeeBps > MAX_WITHDRAWAL_FEE
                || _perfFeeBps > MAX_PERFORMANCE_FEE
        ) revert FeeTooHigh();
        depositFeeBps = _depositFeeBps;
        withdrawFeeBps = _withdrawFeeBps;
        perfFeeBps = _perfFeeBps;
        emit FeesSet(_depositFeeBps, _withdrawFeeBps, _perfFeeBps);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = _feeRecipient;
        emit FeeRecipientSet(_feeRecipient);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _onlyFeeAuthority() internal view {
        if (msg.sender != feeRecipient && msg.sender != owner()) revert NotFeeAuthority();
    }

    // ----------------------------------------------------------------
    // Views
    // ----------------------------------------------------------------

    function positionOf(address user) external view returns (uint256 shares, uint256 hwm) {
        Position storage p = _positions[user];
        return (p.shares, p.hwm);
    }

    /// @notice Current price-per-share (asset units per whole underlying share).
    function pricePerShare() external view returns (uint256) {
        return _currentRatio();
    }

    /// @notice Current asset value of `user`'s position (gross of any future fees).
    function positionValue(address user) external view returns (uint256) {
        return underlying.convertToAssets(_positions[user].shares);
    }

    /// @notice Performance fee (asset units) that would crystallize for `user` right now.
    function pendingPerfFee(address user) external view returns (uint256) {
        Position storage p = _positions[user];
        return HwmFeeMath.perfFeeAssets(p.shares, p.hwm, _currentRatio(), SHARE_UNIT, perfFeeBps);
    }

    /// @notice Preview shares minted for an asset deposit (after the deposit fee).
    function previewDeposit(uint256 assets) external view returns (uint256) {
        (, uint256 net) = HwmFeeMath.splitFeeUp(assets, depositFeeBps);
        return underlying.previewDeposit(net);
    }
}
