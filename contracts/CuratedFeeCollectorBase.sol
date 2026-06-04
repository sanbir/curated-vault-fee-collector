// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {FeeMath} from "./libraries/FeeMath.sol";

/// @title CuratedFeeCollectorBase
/// @notice Thin fee layer on top of a curated ERC-4626 vault (UltraYield / Fluid Lite). The underlying
///         vault keeps its own native fees (charged by P2P/Edge); THIS layer charges the partner's three
///         fees on top and pays them straight to the `partner`:
///           - deposit fee (% of deposit, taken at deposit time),
///           - withdrawal fee (% of redeemed assets, taken at withdrawal),
///           - AUM fee (per-block fraction of redeemed assets, taken at withdrawal).
///         The collector custodies the underlying shares and tracks a NON-TRANSFERABLE per-user position.
///         Both the user and the `partner` can withdraw; assets always go to the user, fees to the partner.
abstract contract CuratedFeeCollectorBase is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_DEPOSIT_FEE = 500; // 5% (BPS)
    uint16 public constant MAX_WITHDRAWAL_FEE = 500; // 5% (BPS)
    uint256 public constant MAX_AUM_FEE_PER_BLOCK = 1e12; // safety cap (WAD/block); real values are tiny

    IERC4626 public immutable underlying;
    IERC20 public immutable asset;

    /// @notice Recipient of all collector fees AND an authorized withdrawer on behalf of users.
    address public partner;
    uint16 public depositFeeBps;
    uint16 public withdrawalFeeBps;
    uint256 public aumFeePerBlock; // WAD-scaled fraction of AUM charged per block

    struct Position {
        uint256 shares; // underlying shares attributed to the user (custodied by this collector)
        uint256 lastBlock; // AUM accrual start block (share-weighted across top-ups)
    }

    mapping(address => Position) internal _positions;
    uint256 public totalShares;

    event Deposited(address indexed user, uint256 assetsIn, uint256 depositFee, uint256 shares);
    event Withdrawn(
        address indexed user,
        address indexed caller,
        uint256 shares,
        uint256 assetsGross,
        uint256 withdrawalFee,
        uint256 aumFee,
        uint256 netToUser
    );
    event FeesSet(uint16 depositFeeBps, uint16 withdrawalFeeBps, uint256 aumFeePerBlock);
    event PartnerSet(address indexed partner);

    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh();
    error InsufficientShares();
    error NotPartner();

    constructor(
        IERC4626 _underlying,
        address _owner,
        address _partner,
        uint16 _depositFeeBps,
        uint16 _withdrawalFeeBps,
        uint256 _aumFeePerBlock
    ) Ownable(_owner) {
        if (address(_underlying) == address(0) || _partner == address(0) || _owner == address(0)) revert ZeroAddress();
        underlying = _underlying;
        asset = IERC20(_underlying.asset());
        partner = _partner;
        _setFees(_depositFeeBps, _withdrawalFeeBps, _aumFeePerBlock);
        IERC20(_underlying.asset()).forceApprove(address(_underlying), type(uint256).max);
    }

    // --------------------------------------------------------------------
    // Deposit (synchronous for both UltraYield and Fluid Lite)
    // --------------------------------------------------------------------

    /// @notice Deposit `assets`; takes the deposit fee to the partner and credits a position to `receiver`.
    function deposit(uint256 assets, address receiver) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        asset.safeTransferFrom(msg.sender, address(this), assets);

        uint256 fee = FeeMath.bpsFee(assets, depositFeeBps);
        if (fee != 0) asset.safeTransfer(partner, fee);

        shares = underlying.deposit(assets - fee, address(this));

        Position storage p = _positions[receiver];
        // Share-weighted AUM start block: defers AUM entirely to withdrawal while staying fair across top-ups.
        if (p.shares == 0) {
            p.lastBlock = block.number;
        } else {
            p.lastBlock = (p.shares * p.lastBlock + shares * block.number) / (p.shares + shares);
        }
        p.shares += shares;
        totalShares += shares;

        emit Deposited(receiver, assets, fee, shares);
    }

    // --------------------------------------------------------------------
    // Fee settlement on exit (shared by the sync + async exit paths)
    // --------------------------------------------------------------------

    /// @dev Splits `assetsGross` into the partner's withdrawal + AUM fee (clamped to gross) and sends the
    ///      remainder to `user`. All fees are paid to the partner in the underlying asset.
    function _chargeAndPay(address user, address caller, uint256 shares, uint256 assetsGross, uint256 lastBlock)
        internal
        returns (uint256 net)
    {
        uint256 wdFee = FeeMath.bpsFee(assetsGross, withdrawalFeeBps);
        if (wdFee > assetsGross) wdFee = assetsGross;
        uint256 aum = FeeMath.aumFee(assetsGross, aumFeePerBlock, block.number - lastBlock);
        uint256 maxAum = assetsGross - wdFee;
        if (aum > maxAum) aum = maxAum;

        uint256 partnerCut = wdFee + aum;
        if (partnerCut != 0) asset.safeTransfer(partner, partnerCut);
        net = assetsGross - partnerCut;
        if (net != 0) asset.safeTransfer(user, net);

        emit Withdrawn(user, caller, shares, assetsGross, wdFee, aum, net);
    }

    // --------------------------------------------------------------------
    // Admin
    // --------------------------------------------------------------------

    function setFees(uint16 _depositFeeBps, uint16 _withdrawalFeeBps, uint256 _aumFeePerBlock) external onlyOwner {
        _setFees(_depositFeeBps, _withdrawalFeeBps, _aumFeePerBlock);
    }

    function _setFees(uint16 _depositFeeBps, uint16 _withdrawalFeeBps, uint256 _aumFeePerBlock) internal {
        if (
            _depositFeeBps > MAX_DEPOSIT_FEE || _withdrawalFeeBps > MAX_WITHDRAWAL_FEE
                || _aumFeePerBlock > MAX_AUM_FEE_PER_BLOCK
        ) revert FeeTooHigh();
        depositFeeBps = _depositFeeBps;
        withdrawalFeeBps = _withdrawalFeeBps;
        aumFeePerBlock = _aumFeePerBlock;
        emit FeesSet(_depositFeeBps, _withdrawalFeeBps, _aumFeePerBlock);
    }

    function setPartner(address _partner) external onlyOwner {
        if (_partner == address(0)) revert ZeroAddress();
        partner = _partner;
        emit PartnerSet(_partner);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _onlyPartner() internal view {
        if (msg.sender != partner) revert NotPartner();
    }

    // --------------------------------------------------------------------
    // Views
    // --------------------------------------------------------------------

    function positionOf(address user) external view returns (uint256 shares, uint256 lastBlock) {
        Position storage p = _positions[user];
        return (p.shares, p.lastBlock);
    }

    /// @notice Current underlying-asset value of `user`'s position (before any fees).
    function positionValue(address user) external view returns (uint256) {
        return underlying.convertToAssets(_positions[user].shares);
    }
}
