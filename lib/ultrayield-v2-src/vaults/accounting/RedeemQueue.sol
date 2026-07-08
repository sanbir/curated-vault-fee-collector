// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PendingRedeem, ClaimableRedeem } from "uyv2/interfaces/Types.sol";
import { IRedeemQueueErrors } from "uyv2/interfaces/IRedeemAccounting.sol";
import { RedeemQueueLib } from "uyv2/utils/RedeemQueueLib.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.RedeemQueue")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant REDEEM_QUEUE_STORAGE_LOCATION = 0x95f12a6101d8197ca778484991e26970e33953d18285b8b9155ec8dca1c42000;

/// @title RedeemQueue
/// @notice Contract to help manage redeems for async vaults
/// @dev Thin wrapper delegating to RedeemQueueLib (external library, called via DELEGATECALL)
/// @dev Internal functions serve as shared JUMP targets, avoiding duplicate DELEGATECALL stubs
abstract contract RedeemQueue is IRedeemQueueErrors {
    function _getPendingRedeem(address user, address token) internal view returns (PendingRedeem memory) {
        return RedeemQueueLib.getPendingRedeem(user, token);
    }

    function _getClaimableRedeem(address user, address token) internal view returns (ClaimableRedeem memory) {
        return RedeemQueueLib.getClaimableRedeem(user, token);
    }

    function _getAutoClaim(address user, address token) internal view returns (bool) {
        return RedeemQueueLib.getAutoClaim(user, token);
    }

    function _calculateClaimableSharesForAssets(address user, address token, uint256 assets) internal view returns (uint256) {
        return RedeemQueueLib.calculateClaimableSharesForAssets(user, token, assets);
    }

    function _calculateClaimableAssetsForShares(address user, address token, uint256 shares) internal view returns (uint256) {
        return RedeemQueueLib.calculateClaimableAssetsForShares(user, token, shares);
    }

    function _increasePendingRedeem(address user, address token, uint256 amount, bool autoClaim) internal {
        RedeemQueueLib.increasePendingRedeem(user, token, amount, autoClaim);
    }

    function _consumePendingRedeem(address user, address token, uint256 amount) internal {
        RedeemQueueLib.consumePendingRedeem(user, token, amount);
    }

    function _increaseClaimableRedeem(address user, address token, uint256 assets, uint256 shares) internal {
        RedeemQueueLib.increaseClaimableRedeem(user, token, assets, shares);
    }

    function _consumeClaimableRedeem(address user, address token, uint256 assets, uint256 shares) internal {
        RedeemQueueLib.consumeClaimableRedeem(user, token, assets, shares);
    }
}
