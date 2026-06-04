// SPDX-FileCopyrightText: 2025 P2P Validator <info@p2p.org>
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
///         fees on top and pays them straight to the partner:
///           - deposit fee (% of deposit, taken at deposit time),
///           - withdrawal fee (% of redeemed assets, taken at withdrawal),
///           - AUM fee (per-block fraction of redeemed assets, taken at withdrawal).
///         The collector custodies the underlying shares and tracks a NON-TRANSFERABLE per-user position.
///         Both the user and the partner can withdraw; assets always go to the user, fees to the partner.
abstract contract CuratedFeeCollectorBase is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 internal constant MAX_DEPOSIT_FEE = 500; // 5% (BPS)
    uint16 internal constant MAX_WITHDRAWAL_FEE = 500; // 5% (BPS)
    uint256 internal constant MAX_AUM_FEE_PER_BLOCK = 1e12; // safety cap (WAD/block); real values are tiny

    IERC4626 internal immutable i_underlying;
    IERC20 internal immutable i_asset;

    /// @dev Recipient of all collector fees AND an authorized withdrawer on behalf of users.
    address internal s_partner;
    uint16 internal s_depositFeeBps;
    uint16 internal s_withdrawalFeeBps;
    uint256 internal s_aumFeePerBlock; // WAD-scaled fraction of AUM charged per block

    struct Position {
        uint256 shares; // underlying shares attributed to the user (custodied by this collector)
        uint256 lastBlock; // AUM accrual start block (share-weighted across top-ups)
    }

    mapping(address => Position) internal s_positions;
    uint256 internal s_totalShares;

    event CuratedFeeCollector__Deposited(address indexed user, uint256 assetsIn, uint256 depositFee, uint256 shares);
    event CuratedFeeCollector__Withdrawn(
        address indexed user,
        address indexed caller,
        uint256 shares,
        uint256 assetsGross,
        uint256 withdrawalFee,
        uint256 aumFee,
        uint256 netToUser
    );
    event CuratedFeeCollector__FeesSet(uint16 depositFeeBps, uint16 withdrawalFeeBps, uint256 aumFeePerBlock);
    event CuratedFeeCollector__PartnerSet(address indexed partner);

    error CuratedFeeCollector__ZeroAddress();
    error CuratedFeeCollector__ZeroAmount();
    error CuratedFeeCollector__FeeTooHigh();
    error CuratedFeeCollector__InsufficientShares();
    error CuratedFeeCollector__NotPartner();

    constructor(
        IERC4626 _underlying,
        address _owner,
        address _partner,
        uint16 _depositFeeBps,
        uint16 _withdrawalFeeBps,
        uint256 _aumFeePerBlock
    ) Ownable(_owner) {
        if (address(_underlying) == address(0) || _partner == address(0) || _owner == address(0)) {
            revert CuratedFeeCollector__ZeroAddress();
        }
        i_underlying = _underlying;
        i_asset = IERC20(_underlying.asset());
        s_partner = _partner;
        _setFees(_depositFeeBps, _withdrawalFeeBps, _aumFeePerBlock);
        IERC20(_underlying.asset()).forceApprove(address(_underlying), type(uint256).max);
    }

    // --------------------------------------------------------------------
    // Deposit (synchronous for both UltraYield and Fluid Lite)
    // --------------------------------------------------------------------

    /// @notice Deposit `_assets`; takes the deposit fee to the partner and credits a position to `_receiver`.
    function deposit(uint256 _assets, address _receiver) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (_assets == 0) revert CuratedFeeCollector__ZeroAmount();
        if (_receiver == address(0)) revert CuratedFeeCollector__ZeroAddress();

        i_asset.safeTransferFrom(msg.sender, address(this), _assets);

        uint256 fee = FeeMath.bpsFee(_assets, s_depositFeeBps);
        if (fee != 0) i_asset.safeTransfer(s_partner, fee);

        shares = i_underlying.deposit(_assets - fee, address(this));

        Position storage p = s_positions[_receiver];
        // Share-weighted AUM start block: defers AUM entirely to withdrawal while staying fair across top-ups.
        if (p.shares == 0) {
            p.lastBlock = block.number;
        } else {
            p.lastBlock = (p.shares * p.lastBlock + shares * block.number) / (p.shares + shares);
        }
        p.shares += shares;
        s_totalShares += shares;

        emit CuratedFeeCollector__Deposited(_receiver, _assets, fee, shares);
    }

    // --------------------------------------------------------------------
    // Fee settlement on exit (shared by the sync + async exit paths)
    // --------------------------------------------------------------------

    /// @dev Splits `_assetsGross` into the partner's withdrawal + AUM fee (clamped to gross) and sends the
    ///      remainder to `_user`. All fees are paid to the partner in the underlying asset.
    function _chargeAndPay(address _user, address _caller, uint256 _shares, uint256 _assetsGross, uint256 _lastBlock)
        internal
        returns (uint256 net)
    {
        uint256 wdFee = FeeMath.bpsFee(_assetsGross, s_withdrawalFeeBps);
        if (wdFee > _assetsGross) wdFee = _assetsGross;
        uint256 aum = FeeMath.aumFee(_assetsGross, s_aumFeePerBlock, block.number - _lastBlock);
        uint256 maxAum = _assetsGross - wdFee;
        if (aum > maxAum) aum = maxAum;

        uint256 partnerCut = wdFee + aum;
        if (partnerCut != 0) i_asset.safeTransfer(s_partner, partnerCut);
        net = _assetsGross - partnerCut;
        if (net != 0) i_asset.safeTransfer(_user, net);

        emit CuratedFeeCollector__Withdrawn(_user, _caller, _shares, _assetsGross, wdFee, aum, net);
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
        ) revert CuratedFeeCollector__FeeTooHigh();
        s_depositFeeBps = _depositFeeBps;
        s_withdrawalFeeBps = _withdrawalFeeBps;
        s_aumFeePerBlock = _aumFeePerBlock;
        emit CuratedFeeCollector__FeesSet(_depositFeeBps, _withdrawalFeeBps, _aumFeePerBlock);
    }

    function setPartner(address _partner) external onlyOwner {
        if (_partner == address(0)) revert CuratedFeeCollector__ZeroAddress();
        s_partner = _partner;
        emit CuratedFeeCollector__PartnerSet(_partner);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _onlyPartner() internal view {
        if (msg.sender != s_partner) revert CuratedFeeCollector__NotPartner();
    }

    // --------------------------------------------------------------------
    // Views
    // --------------------------------------------------------------------

    function getUnderlying() public view virtual returns (IERC4626) {
        return i_underlying;
    }

    function getAsset() public view virtual returns (IERC20) {
        return i_asset;
    }

    function getPartner() public view virtual returns (address) {
        return s_partner;
    }

    function getDepositFeeBps() public view virtual returns (uint16) {
        return s_depositFeeBps;
    }

    function getWithdrawalFeeBps() public view virtual returns (uint16) {
        return s_withdrawalFeeBps;
    }

    function getAumFeePerBlock() public view virtual returns (uint256) {
        return s_aumFeePerBlock;
    }

    function getTotalShares() public view virtual returns (uint256) {
        return s_totalShares;
    }

    function getPosition(address _user) public view virtual returns (uint256 shares, uint256 lastBlock) {
        Position storage p = s_positions[_user];
        return (p.shares, p.lastBlock);
    }

    /// @notice Current underlying-asset value of `_user`'s position (before any fees).
    function getPositionValue(address _user) public view virtual returns (uint256) {
        return i_underlying.convertToAssets(s_positions[_user].shares);
    }
}
