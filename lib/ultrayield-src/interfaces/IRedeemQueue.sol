// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

struct PendingRedeem {
    uint256 shares;
    uint256 requestTime;
}

struct ClaimableRedeem {
    uint256 assets;
    uint256 shares;
}

interface IRedeemQueueErrors {
    error InsufficientPendingShares(uint256 available, uint256 requested);
    error InsufficientClaimableShares(uint256 available, uint256 requested);
    error InsufficientClaimableAssets(uint256 available, uint256 requested);
    error TooManyShares(uint256 shares);
    error TooManyAssets(uint256 assets);
}

interface IRedeemAccounting {
    /// @notice Get controller's pending redeem for the base asset
    /// @param _controller Controller address
    /// @return pendingRedeem Pending redeem details
    function getPendingRedeem(address _controller) external view returns (PendingRedeem memory);

    /// @notice Get controller's pending redeem for the given asset
    /// @param _asset Asset
    /// @param _controller Controller address
    /// @return pendingRedeem Pending redeem details
    function getPendingRedeemForAsset(address _asset, address _controller) external view returns (PendingRedeem memory);

    /// @notice Get controller's claimable redeem for the base asset
    /// @param _controller Controller address
    /// @return claimableRedeem Claimable redeem details
    function getClaimableRedeem(address _controller) external view returns (ClaimableRedeem memory);

    /// @notice Get controller's claimable redeem for the given asset
    /// @param _asset Asset
    /// @param _controller Controller address
    /// @return claimableRedeem Claimable redeem details
    function getClaimableRedeemForAsset(address _asset, address _controller) external view returns (ClaimableRedeem memory);

    /// @notice Get controller's pending shares for the base asset
    /// @param _controller Controller address
    /// @return pendingShares Amount of pending shares
    function pendingRedeemRequest(uint256 /* requestId */, address _controller) external view returns (uint256);

    /// @notice Get controller's pending shares for the given asset
    /// @param _asset Asset
    /// @param _controller Controller address
    /// @return pendingShares Amount of pending shares
    function pendingRedeemRequestForAsset(address _asset, uint256 /* requestId */, address _controller) external view returns (uint256);

    /// @notice Get controller's claimable shares for the base asset
    /// @param _controller Controller address
    /// @return claimableShares Amount of claimable shares
    function claimableRedeemRequest(uint256 /* requestId */, address _controller) external view returns (uint256);

    /// @notice Get controller's claimable shares for the given asset
    /// @param _asset Asset
    /// @param _controller Controller address
    /// @return claimableShares Amount of claimable shares
    function claimableRedeemRequestForAsset(address _asset, uint256 /* requestId */, address _controller) external view returns (uint256);
}
