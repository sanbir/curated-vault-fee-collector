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

    /// @notice Withdraw `shares` of the caller's position; net assets to the caller, fees to the partner.
    function withdraw(uint256 shares) external nonReentrant returns (uint256 net) {
        return _withdraw(msg.sender, msg.sender, shares);
    }

    /// @notice Withdraw the caller's entire position.
    function withdrawAll() external nonReentrant returns (uint256 net) {
        return _withdraw(msg.sender, msg.sender, _positions[msg.sender].shares);
    }

    /// @notice Partner-initiated withdrawal of `shares` from `user`'s position; net assets go to `user`.
    function withdrawFor(address user, uint256 shares) external nonReentrant returns (uint256 net) {
        _onlyPartner();
        return _withdraw(user, msg.sender, shares);
    }

    /// @notice Partner-initiated withdrawal of `user`'s entire position; net assets go to `user`.
    function withdrawAllFor(address user) external nonReentrant returns (uint256 net) {
        _onlyPartner();
        return _withdraw(user, msg.sender, _positions[user].shares);
    }

    /// @dev Synchronous redeem of `shares` from `user`'s position; fees to partner, net to `user`.
    function _withdraw(address user, address caller, uint256 shares) internal returns (uint256) {
        if (shares == 0) revert ZeroAmount();
        Position storage p = _positions[user];
        if (shares > p.shares) revert InsufficientShares();

        uint256 lastBlock = p.lastBlock; // AUM start; preserved for the remainder on partial exits
        p.shares -= shares;
        totalShares -= shares;

        uint256 assetsGross = underlying.redeem(shares, address(this), address(this));
        return _chargeAndPay(user, caller, shares, assetsGross, lastBlock);
    }
}
