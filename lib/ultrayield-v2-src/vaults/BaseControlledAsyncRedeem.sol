// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC165, IERC7575 } from "ERC-7540/interfaces/IERC7575.sol";
import { IERC7540Redeem, IERC7540Operator } from "ERC-7540/interfaces/IERC7540.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PendingRedeem, ClaimableRedeem } from "uyv2/interfaces/Types.sol";
import { IRedeemAccounting } from "uyv2/interfaces/IRedeemAccounting.sol";
import { IUltraVaultRateProvider, Adjustment } from "uyv2/interfaces/IUltraVaultRateProvider.sol";
import { OPERATOR_ROLE, PAUSER_ROLE, UPGRADER_ROLE } from "uyv2/utils/Roles.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { AddressUpdateProposal, AddressUpdatable } from "uyv2/utils/AddressUpdates.sol";
import { RATE_PROVIDER_KEY, UPGRADE_MODULE_KEY } from "uyv2/utils/AddressKeys.sol";
import { RedeemQueue } from "uyv2/vaults/accounting/RedeemQueue.sol";
import { IBaseVaultErrors, IBaseVaultEvents } from "uyv2/interfaces/IBaseVault.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.BaseControlledAsyncRedeem")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant BASE_ASYNC_REDEEM_STORAGE_LOCATION = 0xaf7389673351d5ab654ae6fb9b324c897ebef437a969ec1524dcc6c7b5ca5400;

/// @dev Initialization parameters for BaseControlledAsyncRedeem
struct BaseControlledAsyncRedeemInitParams {
    // Owner of the vault
    address owner;
    // Underlying asset address
    address asset;
    // Vault name
    string name;
    // Vault symbol
    string symbol;
    // Oracle for assets exchange rate
    address rateProvider;
    // External timelocked upgrade module
    address upgradeModule;
}

/// @title BaseControlledAsyncRedeem
/// @notice Base contract for controlled async redeem flows
/// @dev Based on ERC-7540 Reference Implementation
abstract contract BaseControlledAsyncRedeem is
    AccessControlUpgradeable,
    ERC4626Upgradeable,
    PausableUpgradeable,
    AddressUpdatable,
    UUPSUpgradeable,
    RedeemQueue,
    IERC7540Operator,
    IRedeemAccounting,
    IBaseVaultErrors,
    IBaseVaultEvents
{
    using SafeERC20 for IERC20;

    ///////////////
    // Constants //
    ///////////////

    uint256 internal constant REQUEST_ID = 0;
    uint256 internal constant RATE_PROVIDER_TIMELOCK = 3 days;
    uint256 internal constant UPGRADE_MODULE_TIMELOCK = 7 days;

    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.BaseControlledAsyncRedeem
    struct BaseAsyncRedeemStorage {
        mapping(address => mapping(address => bool)) isOperator;
        IUltraVaultRateProvider __rateProvider; // Deprecated in V2
        AddressUpdateProposal __proposedRateProvider; // Deprecated in V2
    }

    /// @dev Returns the namespaced ERC-7201 storage struct for BaseControlledAsyncRedeem
    function _getBaseAsyncRedeemStorage() private pure returns (BaseAsyncRedeemStorage storage $) {
        assembly {
            $.slot := BASE_ASYNC_REDEEM_STORAGE_LOCATION
        }
    }

    /// @dev Copies the legacy V1 rate provider address into V2 address-update storage
    function _migrateBaseControlledAsyncRedeemStateFromV1() internal {
        BaseAsyncRedeemStorage storage $ = _getBaseAsyncRedeemStorage();
        _migrateAddress(RATE_PROVIDER_KEY, address($.__rateProvider));
    }

    //////////
    // Init //
    //////////

    /// @notice Initialize vault with basic parameters
    /// @param params Struct wrapping initialization parameters
    function initialize(
        BaseControlledAsyncRedeemInitParams memory params
    ) public virtual onlyInitializing {
        require(params.asset != address(0), ZeroAssetAddress());

        // Init parents
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ERC20_init(params.name, params.symbol);
        __ERC4626_init(IERC20(params.asset));

        // Init self
        _initAddress(RATE_PROVIDER_KEY, params.rateProvider);
        _initAddress(UPGRADE_MODULE_KEY, params.upgradeModule);

        // Grant roles to owner
        _grantRole(DEFAULT_ADMIN_ROLE, params.owner);
        _grantRole(OPERATOR_ROLE, params.owner);
        _grantRole(PAUSER_ROLE, params.owner);
        _grantRole(UPGRADER_ROLE, params.owner);
    }

    /////////////////
    // Public view //
    /////////////////

    /// @notice Returns the address of the rate provider
    /// @return rateProvider The address of the rate provider
    function rateProvider() public view returns (IUltraVaultRateProvider) {
        return IUltraVaultRateProvider(_getCurrentAddress(RATE_PROVIDER_KEY));
    }

    /// @notice Returns the upgrade module address
    /// @return upgradeModule The address of the upgrade module
    function upgradeModule() public view returns (address) {
        return _getCurrentAddress(UPGRADE_MODULE_KEY);
    }

    /// @notice Returns the proposed address for a given key
    /// @param key The address key (see contract constants)
    /// @return proposedAddress The proposed address and proposal timestamp
    function proposedAddress(bytes32 key) external view returns (address, uint256) {
        return _getAddressUpdateProposal(key);
    }

    //////////////
    // IERC7575 //
    //////////////

    /// @notice Returns the address of the share token
    /// @return share The address of the share token
    function share() public view returns (address) {
        return address(this);
    }

    //////////////////////
    // IERC7540Operator //
    //////////////////////

    /// @inheritdoc IERC7540Operator
    function isOperator(address controller, address operator) public view returns (bool) {
        return _getBaseAsyncRedeemStorage().isOperator[controller][operator];
    }

    /// @inheritdoc IERC7540Operator
    function setOperator(
        address operator,
        bool approved
    ) external returns (bool success) {
        require(msg.sender != operator, CannotSetSelfAsOperator());
        if (isOperator(msg.sender, operator) != approved) {
            _getBaseAsyncRedeemStorage().isOperator[msg.sender][operator] = approved;
            emit OperatorSet(msg.sender, operator, approved);
            success = true;
        }
    }

    //////////////////////
    // Asset Conversion //
    //////////////////////

    /// @notice Converts assets to underlying
    /// @param _asset The asset to convert
    /// @param assets The amount of assets to convert
    /// @param adjustment The adjustment to apply
    /// @return baseAssets The amount of underlying received
    function convertToUnderlying(
        address _asset,
        uint256 assets,
        Adjustment adjustment
    ) public view returns (uint256 baseAssets) {
        // If asset is the same as base asset, no conversion needed
        if (_asset == this.asset()) {
            return assets;
        }
        // Call reverts if asset not supported
        return rateProvider().convertToUnderlying(_asset, assets, adjustment);
    }

    /// @notice Converts underlying to assets
    /// @param _asset The asset to convert
    /// @param baseAssets The amount of underlying to convert
    /// @param adjustment The adjustment to apply
    /// @return assets The amount of assets received
    function convertFromUnderlying(
        address _asset,
        uint256 baseAssets,
        Adjustment adjustment
    ) public view returns (uint256 assets) {
        // If asset is the same as base asset, no conversion needed
        if (_asset == this.asset()) {
            return baseAssets;
        }
        // Call reverts if asset not supported
        return rateProvider().convertFromUnderlying(_asset, baseAssets, adjustment);
    }

    ////////////////////
    // Deposit & Mint //
    ////////////////////

    /// @notice Helper to deposit assets for msg.sender upon referral specifying receiver
    /// @param assets Amount to deposit
    /// @param receiver receiver of deposit
    /// @param referralId id of referral
    /// @return shares Amount of shares received
    function depositWithReferral(
        uint256 assets,
        address receiver,
        string memory referralId
    ) external returns (uint256) {
        return _depositAssetWithReferral(asset(), assets, receiver, referralId);
    }

    /// @notice Helper to deposit particular asset for msg.sender upon referral
    /// @param _asset Asset to deposit
    /// @param assets Amount to deposit
    /// @param receiver receiver of deposit
    /// @param referralId id of referral
    /// @return shares Amount of shares received
    function depositAssetWithReferral(
        address _asset,
        uint256 assets,
        address receiver,
        string memory referralId
    ) external returns (uint256) {
        return _depositAssetWithReferral(_asset, assets, receiver, referralId);
    }

    /// @notice Deposit exact number of assets in base asset and mint shares to receiver
    /// @param assets Amount of assets to deposit
    /// @param receiver Share receiver
    /// @return shares Amount of shares received
    /// @dev Reverts if paused
    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256 shares) {
        return _depositAsset(asset(), assets, receiver);
    }

    /// @notice Deposit assets for receiver
    /// @param _asset Asset
    /// @param assets Amount to deposit
    /// @param receiver Share recipient
    /// @return shares Amount of shares received
    /// @dev Reverts if paused
    function depositAsset(
        address _asset,
        uint256 assets,
        address receiver
    ) external returns (uint256 shares) {
        return _depositAsset(_asset, assets, receiver);
    }

    /// @dev Internal function for processing deposits with referral
    /// @dev Emits Referral event
    function _depositAssetWithReferral(
        address _asset,
        uint256 assets,
        address receiver,
        string memory referralId
    ) internal returns (uint256 shares) {
        shares = _depositAsset(_asset, assets, receiver);
        emit Referral(referralId, msg.sender, shares);
    }

    /// @dev Internal function for depositing exact number of `assets` in `_asset` and minting shares to `receiver`
    /// @dev Reverts if paused
    /// @dev `receiver` is validated to be non-zero within ERC20Upgradeable
    function _depositAsset(
        address _asset,
        uint256 assets,
        address receiver
    ) internal virtual whenNotPaused returns (uint256 shares) {
        shares = previewDepositForAsset(_asset, assets);
        _performDeposit(_asset, assets, shares, receiver);
    }

    /// @notice Mint exact number of shares to receiver and deposit in base asset
    /// @param shares Amount of shares to mint
    /// @param receiver Share receiver
    /// @return assets Amount of assets required
    /// @dev Reverts if paused
    function mint(
        uint256 shares,
        address receiver
    ) public override returns (uint256 assets) {
        return _mintWithAsset(asset(), shares, receiver);
    }

    /// @notice Mint shares for receiver with specific asset
    /// @param _asset Asset to mint with
    /// @param shares Amount to mint
    /// @param receiver Share recipient
    /// @return assets Amount of assets required
    /// @dev Reverts if paused
    function mintWithAsset(
        address _asset,
        uint256 shares,
        address receiver
    ) external returns (uint256 assets) {
        return _mintWithAsset(_asset, shares, receiver);
    }

    /// @dev Internal function for minting exactly `shares` to `receiver` and depositing in `_asset`
    /// @dev Reverts if paused
    /// @dev `receiver` is validated to be non-zero within ERC20Upgradeable
    function _mintWithAsset(
        address _asset,
        uint256 shares,
        address receiver
    ) internal virtual whenNotPaused returns (uint256 assets) {
        assets = previewMintForAsset(_asset, shares);
        _performDeposit(_asset, assets, shares, receiver);
    }

    /// @dev Internal function to process deposit and mint flows
    function _performDeposit(
        address _asset,
        uint256 assets,
        uint256 shares,
        address receiver
    ) internal {
        // Checks
        require(assets != 0, EmptyDeposit());
        require(shares != 0, NothingToMint());

        // Transfer assets from sender to the vault
        IERC20(_asset).safeTransferFrom(
            msg.sender,
            address(this),
            assets
        );

        // Mint shares to receiver
        _mint(receiver, shares);

        // Emit event
        emit Deposit(msg.sender, receiver, assets, shares);

        // Call after-deposit hook - use the actual asset amount that was transferred
        _afterDeposit(_asset, assets, shares, receiver);
    }

    ///////////////////////
    // Withdraw & Redeem //
    ///////////////////////

    /// @notice Withdraw assets from fulfilled redeem requests
    /// @param assets Amount to withdraw
    /// @param receiver Asset recipient
    /// @param controller Controller address
    /// @return shares Amount of shares burned
    /// @dev Asynchronous function, works when paused
    /// @dev Caller must be controller or operator
    /// @dev Requires sufficient claimable assets
    function withdraw(
        uint256 assets,
        address receiver,
        address controller
    ) public override returns (uint256 shares) {
        return _withdrawAsset(asset(), assets, receiver, controller);
    }

    /// @notice Withdraw assets from fulfilled redeem requests
    /// @param _asset Asset
    /// @param assets Amount to withdraw
    /// @param receiver Asset recipient
    /// @param controller Controller address
    /// @return shares Amount of shares burned
    /// @dev Asynchronous function, works when paused
    /// @dev Caller must be controller or operator
    /// @dev Requires sufficient claimable assets
    function withdrawAsset(
        address _asset,
        uint256 assets,
        address receiver,
        address controller
    ) public returns (uint256 shares) {
        return _withdrawAsset(_asset, assets, receiver, controller);
    }

    /// @dev Internal function for withdrawing exact number of `assets` in `_asset`
    function _withdrawAsset(
        address _asset,
        uint256 assets,
        address receiver,
        address controller
    ) internal checkAccess(controller) returns (uint256 shares) {
        require(assets != 0, NothingToWithdraw());
        
        // Calculate shares to burn based on the claimable redeem ratio
        shares = _calculateClaimableSharesForAssets(controller, _asset, assets);
        require(shares != 0, NothingToRedeem());

        // Execute withdraw
        _performWithdraw(_asset, assets, shares, receiver, controller);
    }

    /// @notice Redeem shares from fulfilled requests
    /// @param shares Amount to redeem
    /// @param receiver Asset recipient
    /// @param controller Controller address
    /// @return assets Amount of assets received
    /// @dev Asynchronous function, works when paused
    /// @dev Caller must be controller or operator
    /// @dev Requires sufficient claimable shares
    function redeem(
        uint256 shares,
        address receiver,
        address controller
    ) public override returns (uint256 assets) {
        return _redeemAsset(asset(), shares, receiver, controller);
    }

    /// @notice Redeem shares from fulfilled requests
    /// @param _asset Asset
    /// @param shares Amount to redeem
    /// @param receiver Asset recipient
    /// @param controller Controller address
    /// @return assets Amount of assets received
    /// @dev Asynchronous function, works when paused
    /// @dev Caller must be controller or operator
    /// @dev Requires sufficient claimable shares
    function redeemAsset(
        address _asset,
        uint256 shares,
        address receiver,
        address controller
    ) public returns (uint256 assets) {
        // Shares are already in vault share units, no conversion needed
        return _redeemAsset(_asset, shares, receiver, controller);
    }

    /// @dev Internal function for redeeming exact number of `shares` and withdrawing
    /// @dev assets in `_asset` to `receiver`
    function _redeemAsset(
        address _asset,
        uint256 shares,
        address receiver,
        address controller
    ) internal checkAccess(controller) returns (uint256 assets) {
        require(shares != 0, NothingToRedeem());
        
        // Calculate assets directly in asset units
        assets = _calculateClaimableAssetsForShares(controller, _asset, shares);
        require(assets != 0, NothingToWithdraw());

        // Execute withdraw
        _performWithdraw(_asset, assets, shares, receiver, controller);
    }

    /// @dev Internal function for processing withdraw and redeem flows
    function _performWithdraw(
        address _asset,
        uint256 assets,
        uint256 shares,
        address receiver,
        address controller
    ) internal virtual {
        // Call before-withdrawal hook - use asset units for the hook
        _beforeWithdraw(_asset, assets, shares, receiver, controller);

        // Update claimable redeem
        _consumeClaimableRedeem(controller, _asset, assets, shares);

        // Transfer assets to the receiver
        IERC20(_asset).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    ////////////////
    // Accounting //
    ////////////////

    /// @inheritdoc IRedeemAccounting
    function getPendingRedeem(
        address _asset,
        address _controller
    ) external view returns (PendingRedeem memory) {
        return _getPendingRedeem(_controller, _asset);
    }

    /// @inheritdoc IRedeemAccounting
    function getClaimableRedeem(
        address _asset,
        address _controller
    ) external view returns (ClaimableRedeem memory) {
        return _getClaimableRedeem(_controller, _asset);
    }

    /// @inheritdoc IRedeemAccounting
    function getAutoClaim(
        address _asset,
        address _controller
    ) external view returns (bool) {
        return _getAutoClaim(_controller, _asset);
    }

    /// @inheritdoc IRedeemAccounting
    function pendingRedeemRequest(
        uint256, // requestId
        address _controller
    ) external view returns (uint256) {
        return _getPendingRedeem(_controller, asset()).shares;
    }

    /// @inheritdoc IRedeemAccounting
    function claimableRedeemRequest(
        uint256, // requestId
        address _controller
    ) external view returns (uint256) {
        return _getClaimableRedeem(_controller, asset()).shares;
    }

    /////////////////////////////////
    // Preview Functions Overrides //
    /////////////////////////////////

    /// @notice Preview shares for deposit
    /// @param assets Amount of assets to deposit
    /// @return shares Amount of shares to be received
    /// @dev Returns 0 if vault is paused
    function previewDeposit(
        uint256 assets
    ) public view virtual override returns (uint256) {
        return previewDepositForAsset(asset(), assets);
    }

    /// @notice Preview shares for deposit
    /// @param _asset Asset
    /// @param assets Amount of assets to deposit
    /// @return shares Amount of shares to be received
    /// @dev Returns 0 if vault is paused
    function previewDepositForAsset(
        address _asset,
        uint256 assets
    ) public view virtual returns (uint256) {
        // Convert to underlying for share calculation
        uint256 baseAssets = convertToUnderlying(_asset, assets, Adjustment.DOWN);
        return paused() ? 0 : super.previewDeposit(baseAssets);
    }

    /// @notice Preview assets for mint
    /// @param shares Amount of shares to mint
    /// @return assets Amount of assets required
    /// @dev Returns 0 if vault is paused
    function previewMint(
        uint256 shares
    ) public view virtual override returns (uint256) {
        return previewMintForAsset(asset(), shares);
    }

    /// @notice Preview assets for mint
    /// @param _asset Asset to deposit in
    /// @param shares Amount of shares to mint
    /// @return assets Amount of assets required
    /// @dev Returns 0 if vault is paused
    function previewMintForAsset(
        address _asset,
        uint256 shares
    ) public view virtual returns (uint256) {
        // Calculate assets needed in underlying units, then convert to asset units
        uint256 baseAssets = super.previewMint(shares);
        return paused() ? 0 : convertFromUnderlying(_asset, baseAssets, Adjustment.UP);
    }

    /// @dev Preview withdraw not supported for async flows
    function previewWithdraw(
        uint256
    ) public pure override returns (uint256) {
        revert();
    }

    /// @dev Preview redeem not supported for async flows
    function previewRedeem(
        uint256
    ) public pure override returns (uint256) {
        revert();
    }

    ///////////////////////////////
    // Deposti & Withdraw Limits //
    ///////////////////////////////

    /// @notice Get max assets for deposit
    /// @return assets Maximum deposit amount
    function maxDeposit(
        address // receiver
    ) public view virtual override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    /// @notice Get max shares for mint
    /// @return shares Maximum mint amount
    function maxMint(
        address // receiver
    ) public view virtual override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    /// @notice Get max assets for withdraw
    /// @param controller Controller address
    /// @return assets Maximum withdraw amount
    function maxWithdraw(
        address controller
    ) public view override returns (uint256) {
        return maxWithdrawForAsset(asset(), controller);
    }

    /// @notice Get max assets for withdraw
    /// @param _asset Asset
    /// @param controller Controller address
    /// @return assets Maximum withdraw amount
    function maxWithdrawForAsset(
        address _asset,
        address controller
    ) public view returns (uint256) {
        return _getClaimableRedeem(controller, _asset).assets;
    }

    /// @notice Get max shares for redeem
    /// @param controller Controller address
    function maxRedeem(
        address controller
    ) public view override returns (uint256) {
        return maxRedeemForAsset(asset(), controller);
    }

    /// @notice Get max shares for redeem
    /// @param _asset Asset
    /// @param controller Controller address
    /// @return shares Maximum redeem amount
    function maxRedeemForAsset(
        address _asset,
        address controller
    ) public view returns (uint256) {
        return _getClaimableRedeem(controller, _asset).shares;
    }

    ////////////////////
    // Request Redeem //
    ////////////////////

    /// @notice Request redeem of shares
    /// @param _asset Asset
    /// @param shares Amount to redeem
    /// @param controller Share recipient
    /// @param owner Share owner
    /// @param autoClaim If true, fulfilling this request auto-delivers assets to controller in the same tx
    /// @return requestId Request identifier
    function requestRedeem(
        address _asset,
        uint256 shares,
        address controller,
        address owner,
        bool autoClaim
    ) external returns (uint256 requestId) {
        _ensureIsSupported(_asset);
        return _requestRedeemOfAsset(_asset, shares, controller, owner, autoClaim);
    }

    /// @dev Internal function for processing redeem requests
    function _requestRedeemOfAsset(
        address _asset,
        uint256 shares,
        address controller,
        address owner,
        bool autoClaim
    ) internal checkAccess(owner) returns (uint256 requestId) {
        // Checks
        require(shares != 0, NothingToRedeem());
        require(balanceOf(owner) >= shares, InsufficientBalance());

        // Call before-request-redeem hook
        _beforeRequestRedeem(_asset, shares, controller, owner);

        // Update pending redeem and persist autoClaim preference (last-writer-wins)
        _increasePendingRedeem(controller, _asset, shares, autoClaim);

        // Spend user's shares allowance
        _spendAllowance(owner, address(this), shares);
        // Transfer shares to vault for burning later
        _transfer(owner, address(this), shares);

        // Emit event
        emit RedeemRequest(controller, owner, REQUEST_ID, msg.sender, shares);

        return REQUEST_ID;
    }

    ////////////////////////
    // Redeem Cancelation //
    ////////////////////////

    /// @notice Cancel redeem request for controller
    /// @param _asset Asset
    /// @param controller Controller address
    /// @param receiver Share recipient
    /// @return shares Amount of shares canceled
    /// @dev Transfers pending shares back to receiver
    function cancelRedeemRequest(
        address _asset,
        address controller,
        address receiver
    ) external returns (uint256 shares) {
        shares = _cancelRedeemForAllPendingShares(_asset, controller, receiver);
    }

    /// @notice Cancel redeem request for controller partially, for a specific amount of shares
    /// @param _asset Asset
    /// @param shares Amount of shares to cancel
    /// @param controller Controller address
    /// @param receiver Share recipient
    /// @dev Transfers pending shares back to receiver
    function cancelRedeemRequestPartially(
        address _asset,
        uint256 shares,
        address controller,
        address receiver
    ) external {
        _handleRedeemRequestCancelation(_asset, shares, controller, receiver);
    }

    /// @dev Internal function for canceling redeem requests for all pending shares for a user
    function _cancelRedeemForAllPendingShares(
        address _asset,
        address controller,
        address receiver
    ) internal returns (uint256 shares) {
        shares = _getPendingRedeem(controller, _asset).shares;
        _handleRedeemRequestCancelation(_asset, shares, controller, receiver);
    }

    /// @dev Internal function for canceling redeem requests
    function _handleRedeemRequestCancelation(
        address _asset,
        uint256 shares,
        address controller,
        address receiver
    ) internal virtual checkAccess(controller) {
        // Consume pending redeem
        require(shares != 0, NoPendingRedeem());
        _consumePendingRedeem(controller, _asset, shares);

        // Transfer pending shares from vault to receiver
        _transfer(address(this), receiver, shares);

        // Emit event
        emit RedeemRequestCanceled(controller, receiver, shares);
    }

    ////////////////////////
    // Redeem Fulfillment //
    ////////////////////////

    /// @notice Fulfill multiple redeem requests
    /// @param assets Array of assets
    /// @param shares Array of share amounts
    /// @param controllers Array of controllers
    /// @return Array of fulfilled amounts in requested asset
    /// @dev Reverts if arrays length mismatch
    /// @dev Collects withdrawal fee to incentivize manager
    function fulfillMultipleRedeems(
        address[] memory assets,
        uint256[] memory shares,
        address[] memory controllers
    ) external virtual onlyRole(OPERATOR_ROLE) returns (uint256[] memory) {
        uint256 length = assets.length;
        require(length == shares.length && length == controllers.length, InputLengthMismatch());

        uint256 totalShares;
        uint256[] memory result = new uint256[](length);
        for (uint256 i; i < length; ) {
            // Fulfill redeem
            address _asset = assets[i];
            uint256 _shares = shares[i];
            address _controller = controllers[i];
            uint256 underlyingAssets = convertToAssets(_shares);
            uint256 convertedAssets = convertFromUnderlying(_asset, underlyingAssets, Adjustment.DOWN);
            uint256 assetsFulfilled = _fulfillRedeem(
                _asset,
                convertedAssets,
                _shares,
                _controller
            );

            // Update totals
            result[i] = assetsFulfilled;
            totalShares += _shares;

            unchecked { ++i; }
        }

        // Burn shares
        _burn(address(this), totalShares);

        return result;
    }

    /// @dev Internal fulfill redeem request logic
    function _fulfillRedeem(
        address _asset,
        uint256 assets,
        uint256 shares,
        address controller
    ) internal virtual returns (uint256) {
        // Checks
        require(shares != 0, NothingToRedeem());
        require(assets != 0, NothingToWithdraw());

        // Call before-fulfill redeem hook
        _beforeFulfillRedeem(_asset, assets, shares);

        // Snapshot autoClaim BEFORE consuming pending — the consume clears the flag when shares hit 0
        bool autoClaim = _getAutoClaim(controller, _asset);

        // Update pending and claimable redeems
        _consumePendingRedeem(controller, _asset, shares);
        _increaseClaimableRedeem(controller, _asset, assets, shares);

        // Emit event
        emit RedeemRequestFulfilled(controller, msg.sender, shares, assets);

        // Call after-fulfill redeem hook
        _afterFulfillRedeem(_asset, assets, shares, controller);

        // Auto-claim path: equivalent to the controller invoking `redeem` immediately after fulfillment.
        if (autoClaim) {
            uint256 deliverable = _calculateClaimableAssetsForShares(controller, _asset, shares);
            require(deliverable != 0, NothingToWithdraw());
            _performWithdraw(_asset, deliverable, shares, controller, controller);
        }

        return assets;
    }

    /// @dev Internal helper to check that `_asset` is supported in rateProvider
    function _ensureIsSupported(address _asset) internal view {
        require(rateProvider().isSupported(_asset), AssetNotSupported());
    }

    /////////////////////
    // Address Updates //
    /////////////////////

    /// @notice Propose an address update for the given key
    /// @param key The address key (see contract constants)
    /// @param newAddress The new address being proposed
    function proposeAddressUpdate(bytes32 key, address newAddress) external onlyOwner {
        _timelockForKey(key);
        _proposeAddressUpdate(key, newAddress);
        emit AddressUpdateProposed(key, newAddress);
    }

    /// @notice Accept a previously proposed address update for the given key
    /// @param key The address key (see contract constants)
    /// @param newAddress The address being confirmed (must match the proposal)
    /// @dev Pauses the vault so operators can verify the setup before resuming
    function acceptAddressUpdate(bytes32 key, address newAddress) external onlyOwner {
        uint256 timelock = _timelockForKey(key);
        address oldAddress = _acceptAddressUpdate(key, newAddress, timelock);
        emit AddressUpdated(key, oldAddress, newAddress);

        _pause();
    }

    /// @dev Resolve the per-key timelock duration. Reverts UnknownAddressKey for unsupported keys.
    /// @dev Overrides extend this with additional supported keys and must fall back to `super`.
    function _timelockForKey(bytes32 key) internal pure virtual returns (uint256) {
        if (key == RATE_PROVIDER_KEY) return RATE_PROVIDER_TIMELOCK;
        if (key == UPGRADE_MODULE_KEY) return UPGRADE_MODULE_TIMELOCK;
        revert UnknownAddressKey(key);
    }

    ///////////
    // Hooks //
    ///////////

    /// @dev Hook for executing custom logic right after deposit/mint
    function _afterDeposit(address _asset, uint256 assets, uint256 shares, address receiver) internal virtual {}

    /// @dev Hook for executing custom logic right before withdraw/redeem
    function _beforeWithdraw(address _asset, uint256 assets, uint256 shares, address receiver, address controller) internal virtual {}

    /// @dev Hook for inheriting contracts after request redeem
    function _beforeRequestRedeem(address _asset, uint256 shares, address controller, address owner) internal virtual {}

    /// @dev Hook for inheriting contracts before fulfill
    function _beforeFulfillRedeem(address _asset, uint256 assets, uint256 shares) internal virtual {}

    /// @dev Hook for inheriting contracts after fulfill
    function _afterFulfillRedeem(address _asset, uint256 assets, uint256 shares, address controller) internal virtual {}

    //////////////
    // Pausable //
    //////////////

    /// @notice Check if the contract is paused
    /// @return True if the contract is paused, false otherwise
    function paused() public view override returns (bool) {
        return super.paused();
    }

    /// @notice Pause vault operations
    /// @dev Caller must be owner or have PAUSER_ROLE
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause vault operations
    /// @dev Caller must be owner or have PAUSER_ROLE
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    ////////////////////
    // Access Control //
    ////////////////////

    /// @notice Internal function to ensure caller is owner
    modifier onlyOwner() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), NotOwner());
        _;
    }

    /// @notice Ensure that controller is authorized
    /// @param controller Controller address
    /// @dev Checks if controller is msg.sender or has operator approval
    modifier checkAccess(address controller) {
        require(controller == msg.sender || isOperator(controller, msg.sender), AccessDenied());
        _;
    }

    /// @dev Restricts upgrades to the registered upgrade module
    /// @dev Timelock and UPGRADER_ROLE checks are enforced by the module before it calls back here
    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == upgradeModule(), AccessDenied());
    }

    ////////////
    // ERC165 //
    ////////////

    /// @notice Check interface support
    /// @param interfaceId Interface ID to check
    /// @return exists True if interface is supported
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC7540Redeem).interfaceId ||
            interfaceId == type(IERC7575).interfaceId ||
            interfaceId == type(IERC7540Operator).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
