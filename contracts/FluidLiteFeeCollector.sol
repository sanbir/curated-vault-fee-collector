// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CuratedFeeCollectorBase} from "./CuratedFeeCollectorBase.sol";
import {HwmFeeMath} from "./libraries/HwmFeeMath.sol";

/// @title FluidLiteFeeCollector
/// @notice Per-user HWM fee layer for a *synchronous* ERC-4626 curated vault (e.g. Fluid Lite USD
///         `fLiteUSD`, Fluid Lite ETH `iETHv2`). Exits complete in a single transaction.
contract FluidLiteFeeCollector is CuratedFeeCollectorBase {
    using SafeERC20 for IERC20;

    constructor(
        IERC4626 _underlying,
        address _owner,
        address _feeRecipient,
        uint16 _depositFeeBps,
        uint16 _withdrawFeeBps,
        uint16 _perfFeeBps
    ) CuratedFeeCollectorBase(_underlying, _owner, _feeRecipient, _depositFeeBps, _withdrawFeeBps, _perfFeeBps) {}

    /// @notice Redeem `sharesToRedeem` of the caller's underlying shares for the underlying asset.
    /// @dev    Crystallizes the per-user performance fee first, then charges the withdrawal fee on
    ///         the gross asset proceeds. HWM (a price) is preserved across partial withdrawals.
    /// @return netOut Asset amount sent to `receiver` (after the withdrawal fee).
    function redeem(uint256 sharesToRedeem, address receiver) public nonReentrant returns (uint256 netOut) {
        if (sharesToRedeem == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // Crystallize performance fee (may reduce the caller's share balance).
        _crystallize(msg.sender);

        Position storage p = _positions[msg.sender];
        if (sharesToRedeem > p.shares) revert InsufficientShares();

        uint256 assetsGross = underlying.redeem(sharesToRedeem, address(this), address(this));

        p.shares -= sharesToRedeem;
        totalUserShares -= sharesToRedeem;

        (uint256 wdFee, uint256 net) = HwmFeeMath.splitFeeUp(assetsGross, withdrawFeeBps);
        if (wdFee != 0) asset.safeTransfer(feeRecipient, wdFee);
        asset.safeTransfer(receiver, net);
        netOut = net;

        emit WithdrawalProcessed(msg.sender, receiver, sharesToRedeem, assetsGross, wdFee, net);
    }

    /// @notice Redeem the caller's entire position.
    function withdrawAll(address receiver) external returns (uint256 netOut) {
        // Crystallize first so the redeemed amount reflects the post-fee share balance.
        _crystallize(msg.sender);
        uint256 shares = _positions[msg.sender].shares;
        if (shares == 0) revert InsufficientShares();
        return redeem(shares, receiver);
    }
}
