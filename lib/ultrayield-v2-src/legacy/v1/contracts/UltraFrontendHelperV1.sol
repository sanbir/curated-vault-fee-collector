// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IUltraVaultV1 } from "uyv2/legacy/v1/interfaces/IUltraVaultV1.sol";
import { IUltraFrontendHelper } from "uyv2/interfaces/IUltraFrontendHelper.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.UltraFrontendHelper")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant ULTRA_FRONTEND_HELPER_STORAGE_LOCATION = 0xb0722828b3d7d54293138ffa77a01c09742cd65ca869b0919a7d833efbba8900;

contract UltraFrontendHelperV1 is IUltraFrontendHelper, Ownable2StepUpgradeable, UUPSUpgradeable {
    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.UltraFrontendHelper
    struct Storage {
        address vault;
        address baseAsset;
        address[] additionalAssets;
    }

    function _getStorage() private pure returns (Storage storage $) {
        assembly {
            $.slot := ULTRA_FRONTEND_HELPER_STORAGE_LOCATION
        }
    }

    //////////
    // Init //
    //////////

    constructor() {
        _disableInitializers();
    }
    
    function initialize(address _vault, address _owner, address[] memory _additionalAssets) external initializer {
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        require(_vault != address(0), "Zero vault address");
        Storage storage $ = _getStorage();
        $.vault = _vault;
        $.baseAsset = IUltraVaultV1(_vault).asset();
        $.additionalAssets = _additionalAssets;
    }

    ////////////////////
    // View Functions //
    ////////////////////

    /// @inheritdoc IUltraFrontendHelper
    function getVault() external view returns (address) {
        Storage storage $ = _getStorage();
        return $.vault;
    }
    
    /// @inheritdoc IUltraFrontendHelper
    function getVaultState() external view returns (VaultState memory) {
        IUltraVaultV1 vault = _getVault();
        uint8 decimals = vault.decimals();
        return VaultState({
            totalAssets: vault.totalAssets(),
            totalShares: vault.totalSupply(),
            sharePrice: vault.convertToAssets(10 ** decimals)
        });
    }

    /// @inheritdoc IUltraFrontendHelper
    function previewDeposit(address asset, uint256 amount) external view returns (uint256) {
        IUltraVaultV1 vault = _getVault();
        uint256 baseAssets = vault.convertToUnderlying(asset, amount);
        uint256 shares = vault.convertToShares(baseAssets);
        return shares;
    }

    /// @inheritdoc IUltraFrontendHelper
    function previewRedeem(address asset, uint256 shares) external view returns (uint256) {
        IUltraVaultV1 vault = _getVault();
        uint256 baseAssets = vault.convertToAssets(shares);
        uint256 assets = vault.convertFromUnderlying(asset, baseAssets);
        uint256 withdrawalFee = vault.calculateWithdrawalFee(assets);
        return assets - withdrawalFee;
    }

    /// @inheritdoc IUltraFrontendHelper
    function collectPendingRedeems(address[] calldata users) external view returns (Redeem[] memory redeems) {
        IUltraVaultV1 vault = _getVault();
        address[] memory assets = _getVaultAssets();
        uint256 totalRedeems = 0;
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            for (uint256 j = 0; j < assets.length; j++) {
                uint256 shares = vault.getPendingRedeemForAsset(assets[j], user).shares;
                if (shares > 0) {
                    totalRedeems++;
                }
            }
        }
        if (totalRedeems == 0) {
            return redeems;
        }
        redeems = new Redeem[](totalRedeems);
        uint256 index = 0;
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            for (uint256 j = 0; j < assets.length; j++) {
                address asset = assets[j];
                uint256 shares = vault.getPendingRedeemForAsset(asset, user).shares;
                if (shares > 0) {
                    redeems[index] = Redeem({ user: user, asset: asset, shares: shares });
                    index++;
                }
            }
        }
        return redeems;
    }

    /////////////////////
    // Admin Functions //
    /////////////////////
    
    /// @inheritdoc IUltraFrontendHelper
    function addAsset(address asset) external onlyOwner {
        require(asset != address(0), "Zero asset address");
        require(_getVault().rateProvider().isSupported(asset), "Asset not supported");
        address[] memory assets = _getVaultAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            require(assets[i] != asset, "Duplicate asset");
        }
        _getStorage().additionalAssets.push(asset);
        emit AssetAdded(asset);
    }

    /// @inheritdoc IUltraFrontendHelper
    function removeAsset(address asset) external onlyOwner {
        Storage storage $ = _getStorage();
        bool didRemove = false;
        for (uint256 i = 0; i < $.additionalAssets.length; i++) {
            if ($.additionalAssets[i] == asset) {
                $.additionalAssets[i] = $.additionalAssets[$.additionalAssets.length - 1];
                $.additionalAssets.pop();
                didRemove = true;
                break;
            }
        }
        require(didRemove, "Asset not found");
        emit AssetRemoved(asset);
    }

    //////////////////////
    // Internal helpers //
    //////////////////////

    function _getVault() internal view returns (IUltraVaultV1) {
        Storage storage $ = _getStorage();
        return IUltraVaultV1($.vault);
    }

    function _getVaultAssets() internal view returns (address[] memory) {
        Storage storage $ = _getStorage();
        address[] memory assets = new address[]($.additionalAssets.length + 1);
        assets[0] = $.baseAsset;
        for (uint256 i = 0; i < $.additionalAssets.length; i++) {
            assets[i + 1] = $.additionalAssets[i];
        }
        return assets;
    }

    //////////////////////
    // UUPS Upgradeable //
    //////////////////////

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
