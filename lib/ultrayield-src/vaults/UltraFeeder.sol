// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IUltraVault, Fees } from "src/interfaces/IUltraVault.sol";
import { IUltraFeederErrors } from "src/interfaces/IUltraFeeder.sol";
import { BaseControlledAsyncRedeem, BaseControlledAsyncRedeemInitParams } from "src/vaults/BaseControlledAsyncRedeem.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @dev Initialization parameters for UltraFeeder
struct UltraFeederInitParams {
    // The UltraVault to deposit into
    address mainVault;
    // Owner of the vault
    address owner;
    // Underlying asset address
    address asset;
    // The name of the vault token
    string name;
    // The symbol of the vault token
    string symbol;
}

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.UltraFeeder")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant ULTRA_FEEDER_STORAGE_LOCATION = 0x73fc0f32a78274c31085b0032ea471ff6cedefdd8cffdf1dfa84871cdcb59000;

/// @title UltraFeeder
/// @notice ERC-4626 compliant vault that wraps UltraVault for deposits and handles async redeems
/// @dev This vault only handles deposits into the main UltraVault and manages async redeems
contract UltraFeeder is BaseControlledAsyncRedeem, IUltraFeederErrors {
    using SafeERC20 for IERC20;

    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.UltraFeeder
    struct UltraFeederStorage {
        IUltraVault mainVault;
    }

    function _getUltraFeederStorage() private pure returns (UltraFeederStorage storage $) {
        assembly {
            $.slot := ULTRA_FEEDER_STORAGE_LOCATION
        }
    }

    //////////
    // Init //
    //////////

    /// @notice Disable implementation's initializer
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize UltraFeeder vault
    /// @param params Initialization parameters struct
    function initialize(
        UltraFeederInitParams memory params
    ) external initializer {
        // Validate main vault and base asset
        require(params.mainVault != address(0), ZeroMainVaultAddress());
        IUltraVault mainVault_ = IUltraVault(params.mainVault);
        require(mainVault_.asset() == params.asset, AssetAddressesMismatch());

        // Store main vault
        _getUltraFeederStorage().mainVault = mainVault_;
        
        // Init BaseControlledAsyncRedeem
        super.initialize(BaseControlledAsyncRedeemInitParams({
            owner: params.owner,
            asset: params.asset,
            name: params.name,
            symbol: params.symbol,
            rateProvider: address(mainVault_.rateProvider())
        }));

        // Pause vault in order to be manually checked by the operator
        _pause();
    }

    /////////////
    // Getters //
    /////////////

    /// @notice Get the main vault address
    function mainVault() public view returns (IUltraVault) {
        return _getUltraFeederStorage().mainVault;
    }

    /// @notice Returns the total assets in the vault
    /// @return The total assets in the vault
    function totalAssets() public view override returns (uint256) {
        return mainVault().oracle().getQuote(
            totalSupply(),
            address(mainVault()),
            address(asset())
        );
    }

    ////////////////////////
    // ERC-4626 Overrides //
    ////////////////////////

    /// @notice Returns the amount of shares that would be minted for a given amount of assets
    /// @param assets The amount of assets to convert
    /// @return The amount of shares that would be minted
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return mainVault().previewDeposit(assets);
    }

    /// @notice Preview shares for deposit
    /// @param _asset Asset
    /// @param assets Amount to deposit
    /// @return shares Amount of shares received
    /// @dev Returns 0 if vault is paused
    function previewDepositForAsset(
        address _asset,
        uint256 assets
    ) public view override returns (uint256) {
        return mainVault().previewDepositForAsset(_asset, assets);
    }

    /// @notice Returns the amount of assets required for a given amount of shares
    /// @param shares The amount of shares to convert
    /// @return The amount of assets required
    function previewMint(uint256 shares) public view override returns (uint256) {
        return mainVault().previewMint(shares);
    }

    /// @notice Preview assets for mint
    /// @param _asset Asset to deposit in
    /// @param shares Amount to mint
    /// @return assets Amount of assets required
    /// @dev Returns 0 if vault is paused
    function previewMintForAsset(
        address _asset,
        uint256 shares
    ) public view override returns (uint256) {
        return mainVault().previewMintForAsset(_asset, shares);
    }

    /// @notice Returns the maximum amount of assets that can be deposited
    /// @return The maximum amount of assets that can be deposited
    function maxDeposit(address) public view override returns (uint256) {
        return mainVault().maxDeposit(address(this));
    }

    /// @notice Returns the maximum amount of shares that can be minted
    /// @return The maximum amount of shares that can be minted
    function maxMint(address) public view override returns (uint256) {
        return mainVault().maxMint(address(this));
    }

    ////////////////////////
    // Internal Overrides //
    ////////////////////////

    /// @dev After deposit hook - collect fees and send funds to fundsHolder
    function afterDeposit(address _asset, uint256 assets, uint256 shares) internal override {
        // Approve main vault to spend assets
        IUltraVault _mainVault = mainVault();
        IERC20(_asset).safeIncreaseAllowance(address(_mainVault), assets);

        uint256 mainShares = _mainVault.depositAsset(_asset, assets, address(this));
        require(mainShares == shares, ShareNumberMismatch());
    }

    /// @dev Hook for inheriting contracts after request redeem
    function beforeRequestRedeem(
        address _asset,
        uint256 shares,
        address, // controller
        address  // owner
    ) internal override {
        // Approve main vault to spend it's shares
        IUltraVault _mainVault = mainVault();
        IERC20(_mainVault).safeIncreaseAllowance(address(_mainVault), shares);

        // Request redeem from main vault
        _mainVault.requestRedeemOfAsset(_asset, shares, address(this), address(this));
    }

    /// @dev Before fulfill redeem - transfer funds from fundsHolder to vault
    /// @dev "assets" will already be correct given the token user requested
    function beforeFulfillRedeem(address _asset, uint256 assets, uint256 shares) internal override {
        IUltraVault mainVault_ = mainVault();
        // Fulfill redeem in main vault. Returns asset units
        mainVault_.fulfillRedeem(_asset, shares, address(this));
        uint256 mainAssetsClaimed = mainVault_.redeemAsset(_asset, shares, address(this), address(this));

        // Deduct the expected withdrawal fee from the total amount of assets
        uint256 expectedAssetsAfterFees = assets - mainVault_.calculateWithdrawalFee(assets);
        require(mainAssetsClaimed == expectedAssetsAfterFees, AssetNumberMismatch());
    }

    /// @dev Internal fulfill redeem request logic
    function _fulfillRedeem(
        address _asset,
        uint256 assets,
        uint256 shares,
        address controller
    ) internal override returns (uint256) {
        uint256 assetsFulfilled = super._fulfillRedeem(_asset, assets, shares, controller);
        // Deduct the expected withdrawal fee from the total amount of assets
        uint256 withdrawalFee = mainVault().calculateWithdrawalFee(assetsFulfilled);
        return assetsFulfilled - withdrawalFee;
    }

    /// @dev Hook for inheriting contracts after fulfill redeem
    /// @dev Correct claimable redeem amounts to account for underlying vault fees
    function afterFulfillRedeem(
        address _asset,
        uint256 assets,
        uint256, // shares
        address controller
    ) internal override {
        // The base implementation has added `_assets` to the claimable assets
        // We need to calculate the withdrawal fee and deduct it from the claimable assets
        uint256 withdrawalFee = mainVault().calculateWithdrawalFee(assets);
        _consumeClaimableRedeem(controller, _asset, withdrawalFee, 0);
    }

    /// @dev Internal function for canceling redeem requests
    function _handleRedeemRequestCancelation(
        address _asset,
        uint256 shares,
        address controller,
        address receiver
    ) internal override {
        // First cancel the request in the underlying vault
        // This ensures that the underlying vault's pending redeem is also cleared
        mainVault().cancelRedeemRequestPartially(_asset, shares, address(this), address(this));

        // Then call the internal implementation to handle the feeder's cancellation
        super._handleRedeemRequestCancelation(_asset, shares, controller, receiver);
    }
}
