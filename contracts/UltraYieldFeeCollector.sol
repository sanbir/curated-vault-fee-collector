// SPDX-FileCopyrightText: 2025 P2P Validator <info@p2p.org>
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

    mapping(address => Pending) internal s_pending;
    uint256 internal s_totalPending;

    event UltraYieldFeeCollector__RedeemRequested(
        address indexed user, address indexed caller, uint256 shares, uint256 requestId
    );

    error UltraYieldFeeCollector__NothingToClaim();

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
        return IUltraVault7540(address(i_underlying));
    }

    // --------------------------------------------------------------------
    // Request (user or partner)
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

        requestId = _v().requestRedeem(_shares, address(this), address(this));
        emit UltraYieldFeeCollector__RedeemRequested(_user, msg.sender, _shares, requestId);
    }

    // --------------------------------------------------------------------
    // Claim (user or partner) — fees charged here; assets to the user
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
        if (toClaim == 0) revert UltraYieldFeeCollector__NothingToClaim();

        uint256 lastBlock = pe.lastBlock;
        uint256 assetsGross = _v().redeem(toClaim, address(this), address(this));

        pe.shares = ps - toClaim;
        s_totalPending -= toClaim;

        return _chargeAndPay(_user, msg.sender, toClaim, assetsGross, lastBlock);
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
}
