// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IRedeemQueueErrors, PendingRedeem, ClaimableRedeem } from "src/interfaces/IRedeemQueue.sol";
import { FixedPointMathLib } from "src/utils/FixedPointMathLib.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.RedeemQueue")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant REDEEM_QUEUE_STORAGE_LOCATION = 0x95f12a6101d8197ca778484991e26970e33953d18285b8b9155ec8dca1c42000;

/// @title RedeemQueue
/// @notice Contract to help manage redeems for async vaults
abstract contract RedeemQueue is IRedeemQueueErrors {
    using FixedPointMathLib for uint256;

    ///////////////
    // Constants //
    ///////////////

    uint256 internal constant UINT128_MAX = type(uint128).max;

    /////////////
    // Storage //
    /////////////

    /// @dev Represents a single storage slot for a pending redeem
    struct PendingRedeemSlot {
        uint128 shares;
        uint128 requestTime;
    }

    /// @dev Represents a single storage slot for a claimable redeem
    struct ClaimableRedeemSlot {
        uint128 assets;
        uint128 shares;
    }

    /// @custom:storage-location erc7201:ultrayield.storage.RedeemQueue
    struct Storage {
        mapping(address => mapping(address => PendingRedeemSlot)) pendingRedeems;
        mapping(address => mapping(address => ClaimableRedeemSlot)) claimableRedeems;
    }

    function _getRedeemQueueStorage() private pure returns (Storage storage $) {
        assembly {
            $.slot := REDEEM_QUEUE_STORAGE_LOCATION
        }
    }

    /////////////////////////////
    // Internal View Functions //
    /////////////////////////////

    function _getPendingRedeem(
        address user,
        address token
    ) internal view returns (PendingRedeem memory) {
        PendingRedeemSlot memory redeem = _getRedeemQueueStorage().pendingRedeems[user][token];
        return PendingRedeem({
            shares: redeem.shares,
            requestTime: redeem.requestTime
        });
    }

    function _getClaimableRedeem(
        address user,
        address token
    ) internal view returns (ClaimableRedeem memory) {
        ClaimableRedeemSlot memory redeem = _getRedeemQueueStorage().claimableRedeems[user][token];
        return ClaimableRedeem({
            shares: redeem.shares,
            assets: redeem.assets
        });
    }

    function _calculateClaimableSharesForAssets(
        address user,
        address token,
        uint256 assets
    ) internal view returns (uint256 shares) {
        ClaimableRedeemSlot memory redeem = _getRedeemQueueStorage().claimableRedeems[user][token];
        if (assets == redeem.assets) {
            return redeem.shares;
        } else {
            require(assets < redeem.assets, InsufficientClaimableAssets(redeem.assets, assets));
            return assets.mulDivUp(redeem.shares, redeem.assets);
        }
    }

    function _calculateClaimableAssetsForShares(
        address user,
        address token,
        uint256 shares
    ) internal view returns (uint256 assets) {
        ClaimableRedeemSlot memory redeem = _getRedeemQueueStorage().claimableRedeems[user][token];
        if (shares == redeem.shares) {
            return redeem.assets;
        } else {
            require(shares < redeem.shares, InsufficientClaimableShares(redeem.shares, shares));
            return shares.mulDivDown(redeem.assets, redeem.shares);
        }
    }

    ///////////////////////////
    // Update Pending Redeem //
    ///////////////////////////

    function _increasePendingRedeem(
        address user,
        address token,
        uint256 amount
    ) internal {
        PendingRedeemSlot storage pending = _getRedeemQueueStorage().pendingRedeems[user][token];
        uint256 newShares = uint256(pending.shares) + amount;
        require(newShares <= UINT128_MAX, TooManyShares(newShares));
        pending.shares = uint128(newShares);
        pending.requestTime = uint128(block.timestamp);
    }

    function _consumePendingRedeem(
        address user,
        address token,
        uint256 amount
    ) internal {
        PendingRedeemSlot storage pending = _getRedeemQueueStorage().pendingRedeems[user][token];
        require(amount <= pending.shares, InsufficientPendingShares(pending.shares, amount));
        pending.shares -= uint128(amount);
        if (pending.shares == 0) {
            pending.requestTime = 0;
        }
    }

    /////////////////////////////
    // Update Claimable Redeem //
    /////////////////////////////

    function _increaseClaimableRedeem(
        address user,
        address token,
        uint256 assets,
        uint256 shares
    ) internal {
        ClaimableRedeemSlot storage redeem = _getRedeemQueueStorage().claimableRedeems[user][token];
        uint256 newAssets = uint256(redeem.assets) + assets;
        uint256 newShares = uint256(redeem.shares) + shares;
        require(newAssets <= UINT128_MAX, TooManyAssets(newAssets));
        require(newShares <= UINT128_MAX, TooManyShares(newShares));
        redeem.assets = uint128(newAssets);
        redeem.shares = uint128(newShares);
    }

    function _consumeClaimableRedeem(
        address user,
        address token,
        uint256 assets,
        uint256 shares
    ) internal {
        ClaimableRedeemSlot storage redeem = _getRedeemQueueStorage().claimableRedeems[user][token];
        require(assets <= redeem.assets, InsufficientClaimableAssets(redeem.assets, assets));
        require(shares <= redeem.shares, InsufficientClaimableShares(redeem.shares, shares));
        redeem.assets -= uint128(assets);
        redeem.shares -= uint128(shares);
    }
}
