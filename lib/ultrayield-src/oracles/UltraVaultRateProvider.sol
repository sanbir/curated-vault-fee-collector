// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IRateProvider } from "src/interfaces/IRateProvider.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { TimelockedUUPSUpgradeable } from "src/utils/TimelockedUUPSUpgradeable.sol";
import { IUltraVaultRateProvider, AssetData } from "src/interfaces/IUltraVaultRateProvider.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.UltraVaultRateProvider")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant ULTRA_VAULT_RATE_PROVIDER_STORAGE_LOCATION = 0xe24c98638c43dd52672effcbc76556d36ab0c9a1bbbb5f4a3c1e3bd83e851000;

/// @title UltraVaultRateProvider
/// @notice Handles rate calculations between assets for UltraVault
contract UltraVaultRateProvider is Ownable2StepUpgradeable, TimelockedUUPSUpgradeable, IUltraVaultRateProvider {
    ///////////////
    // Constants //
    ///////////////

    uint8 internal constant MIN_DECIMALS = 6;
    uint8 internal constant MAX_DECIMALS = 18;

    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.UltraVaultRateProvider
    struct Storage {
        address baseAsset;
        uint8 decimals;
        mapping(address => AssetData) supportedAssets;
    }

    function _getStorage() private pure returns (Storage storage $) {
        assembly {
            $.slot := ULTRA_VAULT_RATE_PROVIDER_STORAGE_LOCATION
        }
    }

    //////////
    // Init //
    //////////

    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address _baseAsset) external initializer {
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __TimelockedUUPSUpgradeable_init();

        uint8 _decimals = IERC20Metadata(_baseAsset).decimals();
        _validateDecimals(_decimals);

        Storage storage $ = _getStorage();
        $.baseAsset = _baseAsset;
        $.decimals = _decimals;
        // Base asset is always supported and pegged to itself
        $.supportedAssets[_baseAsset] = AssetData({
            isPegged: true,
            decimals: _decimals,
            rateProvider: address(0)
        });
        emit AssetAdded(address(_baseAsset), true);
    }

    /////////////////////////////
    // IUltraVaultRateProvider //
    /////////////////////////////

    /// @inheritdoc IUltraVaultRateProvider
    function baseAsset() public view returns (address) {
        return _getStorage().baseAsset;
    }

    /// @inheritdoc IUltraVaultRateProvider
    function decimals() public view returns (uint8) {
        return _getStorage().decimals;
    }

    /// @inheritdoc IUltraVaultRateProvider
    function supportedAssets(address asset) public view returns (AssetData memory) {
        return _getStorage().supportedAssets[asset];
    }

    /// @inheritdoc IUltraVaultRateProvider
    function isSupported(address asset) external view returns (bool) {
        AssetData memory data = _getStorage().supportedAssets[asset];
        return data.isPegged || data.rateProvider != address(0);
    }

    /// @inheritdoc IUltraVaultRateProvider
    function addAsset(address asset, bool isPegged, address rateProvider) external onlyOwner {
        // Checks
        Storage storage $ = _getStorage();
        AssetData memory data = $.supportedAssets[asset];
        require(!data.isPegged && data.rateProvider == address(0), AssetAlreadySupported());
        if (isPegged) {
            require(rateProvider == address(0), InvalidRateProvider());
        } else {
            require(rateProvider != address(0), InvalidRateProvider());
        }

        // Update storage
        uint8 _decimals = IERC20Metadata(asset).decimals();
        _validateDecimals(_decimals);
        $.supportedAssets[asset] = AssetData({
            isPegged: isPegged,
            decimals: _decimals,
            rateProvider: rateProvider
        });

        // Emit events
        emit AssetAdded(address(asset), isPegged);
        if (!isPegged) {
            emit RateProviderUpdated(address(asset), rateProvider);
        }
    }

    /// @inheritdoc IUltraVaultRateProvider
    function removeAsset(address asset) external onlyOwner {
        Storage storage $ = _getStorage();
        require(asset != $.baseAsset, CannotUpdateBaseAsset());
        delete $.supportedAssets[asset];
        emit AssetRemoved(asset);
    }

    /// @inheritdoc IUltraVaultRateProvider
    function updateRateProvider(address asset, address rateProvider) external onlyOwner {
        Storage storage $ = _getStorage();
        require(asset != $.baseAsset, CannotUpdateBaseAsset());
        require(!$.supportedAssets[asset].isPegged, AssetNotSupported());
        require(rateProvider != address(0), InvalidRateProvider());

        $.supportedAssets[asset].rateProvider = rateProvider;
        emit RateProviderUpdated(address(asset), rateProvider);
    }

    /// @inheritdoc IUltraVaultRateProvider
    function convertToUnderlying(address asset, uint256 assets) external view returns (uint256 result) {
        Storage storage $ = _getStorage();
        AssetData memory data = $.supportedAssets[asset];
        if (data.isPegged) {
            return _convertDecimals(assets, data.decimals, $.decimals);
        } else {
            require(data.rateProvider != address(0), AssetNotSupported());
            // Call external rate provider
            return IRateProvider(data.rateProvider).convertToUnderlying(asset, assets);
        }
    }

    /// @inheritdoc IUltraVaultRateProvider
    function convertFromUnderlying(address asset, uint256 baseAssets) external view returns (uint256 result) {
        Storage storage $ = _getStorage();
        AssetData memory data = $.supportedAssets[asset];
        if (data.isPegged) {
            return _convertDecimals(baseAssets, $.decimals, data.decimals);
        } else {
            require(data.rateProvider != address(0), AssetNotSupported());
            // Call external rate provider
            return IRateProvider(data.rateProvider).convertFromUnderlying(asset, baseAssets);
        }
    }

    //////////////////////
    // Internal Helpers //
    //////////////////////

    /// @dev Helps with decimals accounting
    function _convertDecimals(
        uint256 amount, 
        uint8 fromDecimals, 
        uint8 toDecimals
    ) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals < toDecimals) {
            uint8 diff;
            unchecked { diff = toDecimals - fromDecimals; }
            return amount * 10 ** diff;
        } else {
            uint8 diff;
            unchecked { diff = fromDecimals - toDecimals; }
            return amount / 10 ** diff;
        }
    }

    /// @dev Validates that the given decimals value lies within the allowed range
    function _validateDecimals(uint8 _decimals) internal pure {
        require(_decimals >= MIN_DECIMALS && _decimals <= MAX_DECIMALS, InvalidDecimals());
    }

    ////////////////////////////
    // Upgrade Access Control //
    ////////////////////////////

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _authorizeUpgradeProposal() internal override onlyOwner {}

    function _authorizeUpgradeCancellation() internal override onlyOwner {}
} 
