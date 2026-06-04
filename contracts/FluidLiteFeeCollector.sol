// SPDX-FileCopyrightText: 2025 P2P Validator <info@p2p.org>
// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {CuratedFeeCollectorBase} from "./CuratedFeeCollectorBase.sol";

/// @title FluidLiteFeeCollector
/// @notice Partner fee layer for a SYNCHRONOUS ERC-4626 curated vault (e.g. Fluid Lite USD `fLiteUSD`).
///         Withdrawals complete in one transaction. Both the user and the partner can withdraw; assets go
///         to the user, fees to the partner.
contract FluidLiteFeeCollector is CuratedFeeCollectorBase {
    constructor(
        IERC4626 _underlying,
        address _owner,
        address _partner,
        uint16 _depositFeeBps,
        uint16 _withdrawalFeeBps,
        uint256 _aumFeePerBlock
    ) CuratedFeeCollectorBase(_underlying, _owner, _partner, _depositFeeBps, _withdrawalFeeBps, _aumFeePerBlock) {}

    /// @notice Withdraw `_shares` of the caller's position; net assets to the caller, fees to the partner.
    function withdraw(uint256 _shares) external nonReentrant returns (uint256 net) {
        return _withdraw(msg.sender, msg.sender, _shares);
    }

    /// @notice Withdraw the caller's entire position.
    function withdrawAll() external nonReentrant returns (uint256 net) {
        return _withdraw(msg.sender, msg.sender, s_positions[msg.sender].shares);
    }

    /// @notice Partner-initiated withdrawal of `_shares` from `_user`'s position; net assets go to `_user`.
    function withdrawFor(address _user, uint256 _shares) external nonReentrant returns (uint256 net) {
        _onlyPartner();
        return _withdraw(_user, msg.sender, _shares);
    }

    /// @notice Partner-initiated withdrawal of `_user`'s entire position; net assets go to `_user`.
    function withdrawAllFor(address _user) external nonReentrant returns (uint256 net) {
        _onlyPartner();
        return _withdraw(_user, msg.sender, s_positions[_user].shares);
    }

    /// @dev Synchronous redeem of `_shares` from `_user`'s position; fees to partner, net to `_user`.
    function _withdraw(address _user, address _caller, uint256 _shares) internal returns (uint256) {
        if (_shares == 0) revert CuratedFeeCollector__ZeroAmount();
        Position storage p = s_positions[_user];
        if (_shares > p.shares) revert CuratedFeeCollector__InsufficientShares();

        uint256 lastBlock = p.lastBlock; // AUM start; preserved for the remainder on partial exits
        p.shares -= _shares;
        s_totalShares -= _shares;

        uint256 assetsGross = i_underlying.redeem(_shares, address(this), address(this));
        return _chargeAndPay(_user, _caller, _shares, assetsGross, lastBlock);
    }
}
