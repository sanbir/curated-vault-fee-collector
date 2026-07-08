// SPDX-FileCopyrightText: 2026 P2P Validator <info@p2p.org>
// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CuratedFeeCollectorBase} from "./CuratedFeeCollectorBase.sol";
import {IUltraVaultV2} from "./interfaces/IUltraVaultV2.sol";

/// @title UltraYieldV2FeeCollector
/// @notice Partner fee layer for UltraYield's **V2** vault. Like the V1 collector, it custodies the
///         underlying shares and tracks a NON-TRANSFERABLE per-user position, charging the partner's
///         deposit / withdrawal / AUM fees on top of the vault's own native fees.
///
///         V2 adds a second exit route, so this collector exposes two of them:
///           1. ASYNC (`requestRedeem` -> operator `fulfillMultipleRedeems` -> `claim`): partner
///              withdrawal + AUM fees are charged at claim. V2's `requestRedeem` takes a leading asset
///              and a trailing `autoClaim` flag; the collector always requests with `autoClaim=false`
///              so it controls fee settlement at claim time.
///           2. INSTANT (`instantRedeem`): a synchronous exit drawing on the vault's exitpoint liquidity.
///              Partner withdrawal + AUM fees are charged in the same call. Subject to the vault having
///              enough instant-redeem liquidity.
///
///         In both routes assets go to the user and fees to the partner. Both the user and the partner
///         can drive either route (the partner via the `*For` variants).
///
///         Deposits reuse the underlying UltraYield vault's KYC list: both the account funding the
///         deposit and the beneficiary receiving the internal position must currently be allowed.
///         Exit paths intentionally do not repeat this check, so later allowlist removal cannot trap
///         shares already custodied by the collector.
contract UltraYieldV2FeeCollector is CuratedFeeCollectorBase {
    using SafeERC20 for IERC20;

    struct Pending {
        uint256 shares;
        uint256 lastBlock; // AUM start block carried from the position at request time
    }

    mapping(address => Pending) internal s_pending;
    uint256 internal s_totalPending;

    event UltraYieldV2FeeCollector__RedeemRequested(
        address indexed user, address indexed caller, uint256 shares, uint256 requestId
    );
    event UltraYieldV2FeeCollector__InstantRedeemed(
        address indexed user, address indexed caller, uint256 shares, uint256 grossFromVault, uint256 netToUser
    );

    error UltraYieldV2FeeCollector__NothingToClaim();
    error UltraYieldV2FeeCollector__SlippageExceeded(uint256 net, uint256 minNet);
    error UltraYieldV2FeeCollector__NotAllowed(address account);

    constructor(
        IERC4626 _underlying,
        address _owner,
        address _partner,
        uint16 _depositFeeBps,
        uint16 _withdrawalFeeBps,
        uint256 _aumFeePerBlock
    ) CuratedFeeCollectorBase(_underlying, _owner, _partner, _depositFeeBps, _withdrawalFeeBps, _aumFeePerBlock) {
        // Async requestRedeem pulls the collector's shares via _spendAllowance(owner, vault); the share
        // token IS the vault, so pre-approve the vault to move the collector's own shares.
        IERC20(address(_underlying)).forceApprove(address(_underlying), type(uint256).max);
    }

    function _v() private view returns (IUltraVaultV2) {
        return IUltraVaultV2(address(i_underlying));
    }

    /// @dev Reuse UltraYield's KYC list for both the source of funds and the internal position owner.
    ///      This hook only runs on deposit: later removal from the list must not trap an existing position.
    function _beforeDeposit(address _funder, address _receiver) internal view override {
        if (!_v().isAllowed(_funder)) revert UltraYieldV2FeeCollector__NotAllowed(_funder);
        if (!_v().isAllowed(_receiver)) revert UltraYieldV2FeeCollector__NotAllowed(_receiver);
    }

    // --------------------------------------------------------------------
    // Async exit: request (user or partner)
    // --------------------------------------------------------------------

    function requestRedeem(uint256 _shares) external nonReentrant returns (uint256 requestId) {
        return _request(msg.sender, _shares);
    }

    function requestRedeemAll() external nonReentrant returns (uint256 requestId) {
        return _request(msg.sender, s_positions[msg.sender].shares);
    }

    function requestRedeemFor(address _user, uint256 _shares) external nonReentrant returns (uint256 requestId) {
        _onlyPartner();
        return _request(_user, _shares);
    }

    function requestRedeemAllFor(address _user) external nonReentrant returns (uint256 requestId) {
        _onlyPartner();
        return _request(_user, s_positions[_user].shares);
    }

    function _request(address _user, uint256 _shares) internal returns (uint256 requestId) {
        if (_shares == 0) revert CuratedFeeCollector__ZeroAmount();
        Position storage p = s_positions[_user];
        if (_shares > p.shares) revert CuratedFeeCollector__InsufficientShares();

        Pending storage pe = s_pending[_user];
        // Carry the AUM start block into the pending parcel (share-weighted across multiple requests).
        if (pe.shares == 0) {
            pe.lastBlock = p.lastBlock;
        } else {
            pe.lastBlock = (pe.shares * pe.lastBlock + _shares * p.lastBlock) / (pe.shares + _shares);
        }

        p.shares -= _shares;
        s_totalShares -= _shares;
        pe.shares += _shares;
        s_totalPending += _shares;

        requestId = _v().requestRedeem(address(i_asset), _shares, address(this), address(this), false);
        emit UltraYieldV2FeeCollector__RedeemRequested(_user, msg.sender, _shares, requestId);
    }

    // --------------------------------------------------------------------
    // Async exit: claim (user or partner) — fees charged here; assets to the user
    // --------------------------------------------------------------------

    function claim() external nonReentrant returns (uint256 net) {
        return _claim(msg.sender);
    }

    function claimFor(address _user) external nonReentrant returns (uint256 net) {
        _onlyPartner();
        return _claim(_user);
    }

    function _claim(address _user) internal returns (uint256 net) {
        Pending storage pe = s_pending[_user];
        uint256 ps = pe.shares;
        if (ps == 0) revert CuratedFeeCollector__ZeroAmount();

        uint256 claimable = _v().maxRedeem(address(this));
        uint256 toClaim = ps < claimable ? ps : claimable;
        if (toClaim == 0) revert UltraYieldV2FeeCollector__NothingToClaim();

        uint256 lastBlock = pe.lastBlock;
        uint256 assetsGross = _v().redeem(toClaim, address(this), address(this));

        pe.shares = ps - toClaim;
        s_totalPending -= toClaim;

        return _chargeAndPay(_user, msg.sender, toClaim, assetsGross, lastBlock);
    }

    // --------------------------------------------------------------------
    // Instant exit (V2 only): synchronous redeem against exitpoint liquidity
    // --------------------------------------------------------------------

    /// @notice Instantly redeem `_shares` of the caller's position. `_minNetToUser` bounds the net the
    ///         user receives after partner fees (0 to disable). Reverts if the vault lacks instant liquidity.
    function instantRedeem(uint256 _shares, uint256 _minNetToUser) external nonReentrant returns (uint256 net) {
        return _instant(msg.sender, _shares, _minNetToUser);
    }

    function instantRedeemAll(uint256 _minNetToUser) external nonReentrant returns (uint256 net) {
        return _instant(msg.sender, s_positions[msg.sender].shares, _minNetToUser);
    }

    function instantRedeemFor(address _user, uint256 _shares, uint256 _minNetToUser)
        external
        nonReentrant
        returns (uint256 net)
    {
        _onlyPartner();
        return _instant(_user, _shares, _minNetToUser);
    }

    function _instant(address _user, uint256 _shares, uint256 _minNetToUser) internal returns (uint256 net) {
        if (_shares == 0) revert CuratedFeeCollector__ZeroAmount();
        Position storage p = s_positions[_user];
        if (_shares > p.shares) revert CuratedFeeCollector__InsufficientShares();

        uint256 lastBlock = p.lastBlock;
        p.shares -= _shares;
        s_totalShares -= _shares;

        // Vault burns the collector's shares and pays net-of-vault-fee assets to the collector.
        uint256 grossFromVault = _v().instantRedeem(address(i_asset), _shares, 0, address(this), address(this));

        // Charge partner fees on top of what the vault paid out; remainder goes to the user.
        net = _chargeAndPay(_user, msg.sender, _shares, grossFromVault, lastBlock);
        if (net < _minNetToUser) revert UltraYieldV2FeeCollector__SlippageExceeded(net, _minNetToUser);

        emit UltraYieldV2FeeCollector__InstantRedeemed(_user, msg.sender, _shares, grossFromVault, net);
    }

    // --------------------------------------------------------------------
    // Views
    // --------------------------------------------------------------------

    function getPending(address _user) public view virtual returns (uint256 shares, uint256 lastBlock) {
        Pending storage pe = s_pending[_user];
        return (pe.shares, pe.lastBlock);
    }

    function getTotalPending() public view virtual returns (uint256) {
        return s_totalPending;
    }

    /// @notice Instant-redeem liquidity currently available in the vault for the collector's asset.
    function getInstantLiquidity() external view returns (uint256) {
        return _v().getLiquidity(address(i_asset));
    }
}
