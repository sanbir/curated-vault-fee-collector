// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC165 } from "@openzeppelin/contracts/interfaces/IERC165.sol";
import { IAccessControlDefaultAdminRules } from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import { IPausable } from "uyv2/interfaces/IPausable.sol";
import { IERC7540Operator } from "ERC-7540/interfaces/IERC7540.sol";
import { IRedeemAccounting } from "uyv2/interfaces/IRedeemAccounting.sol";
import { IAddressUpdatableErrors } from "uyv2/interfaces/IAddressUpdatableErrors.sol";
import { IUltraVaultRateProvider } from "uyv2/interfaces/IUltraVaultRateProvider.sol";
import { Adjustment } from "uyv2/interfaces/Types.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC165 } from "@openzeppelin/contracts/interfaces/IERC165.sol";

interface IBaseVaultErrors is IAddressUpdatableErrors {
    error NotOwner();
    error AccessDenied();
    error ZeroAssetAddress();
    error InputLengthMismatch();
    error EmptyDeposit();
    error NothingToMint();
    error NothingToRedeem();
    error NothingToWithdraw();
    error NoPendingRedeem();
    error InsufficientBalance();
    error AssetNotSupported();
    error CannotSetSelfAsOperator();
}

interface IBaseVaultEvents {
    event AddressUpdateProposed(bytes32 indexed key, address indexed newAddress);
    event AddressUpdated(bytes32 indexed key, address indexed oldAddress, address indexed newAddress);
    event RedeemRequestFulfilled(
        address indexed controller,
        address indexed fulfiller,
        uint256 shares,
        uint256 assets
    );
    event RedeemRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 shares
    );
    event RedeemRequestCanceled(
        address indexed controller,
        address indexed receiver,
        uint256 shares
    );
    event Referral(string indexed referralId, address indexed user, uint256 shares);
}

/// @title IBaseVault
/// @notice An interface of basic vault functionality for both UltraVault and UltraFeeder contracts
interface IBaseVault is 
  IBaseVaultEvents,
  IBaseVaultErrors,
  IERC20,
  IERC165,
  IERC4626,
  IAccessControl,
  IPausable,
  IERC7540Operator,
  IRedeemAccounting 
{
    ////////////////////
    // View Functions //
    ////////////////////

    /// @notice Returns the address of the share token
    /// @return share The address of the share token
    function share() external view returns (address);

    /// @notice Returns the address of the rate provider
    /// @return rateProvider The address of the rate provider
    function rateProvider() external view returns (IUltraVaultRateProvider);

    /// @notice Returns the address of the upgrade module
    /// @return upgradeModule The address of the upgrade module
    function upgradeModule() external view returns (address);

    /// @notice Returns the proposed address for a given key
    /// @param key The address key (see contract NatSpec for precomputed hashes)
    /// @return proposedAddress The proposed address and proposal timestamp
    function proposedAddress(bytes32 key) external view returns (address, uint256);

    /// @notice Converts assets to underlying
    /// @param asset The asset to convert
    /// @param assets The amount of assets to convert
    /// @param adjustment The adjustment to apply
    /// @return baseAssets The amount of underlying received
    function convertToUnderlying(
        address asset,
        uint256 assets,
        Adjustment adjustment
    ) external view returns (uint256 baseAssets);

    /// @notice Converts underlying to assets
    /// @param asset The asset to convert
    /// @param baseAssets The amount of underlying to convert
    /// @param adjustment The adjustment to apply
    /// @return assets The amount of assets received
    function convertFromUnderlying(
        address asset,
        uint256 baseAssets,
        Adjustment adjustment
    ) external view returns (uint256 assets);

    /////////////
    // Deposit //
    /////////////

    /// @notice Get max assets for deposit
    /// @return assets Maximum deposit amount
    function maxDeposit(
        address
    ) external view returns (uint256);

    /// @notice Preview shares for deposit
    /// @param assets Amount to deposit
    /// @return shares Amount of shares received
    function previewDeposit(
        uint256 assets
    ) external view returns (uint256);

    /// @notice Preview shares for deposit
    /// @param asset Asset
    /// @param assets Amount to deposit
    /// @return shares Amount of shares received
    function previewDepositForAsset(
        address asset,
        uint256 assets
    ) external view returns (uint256);

    /// @notice Deposit exact number of assets in base asset and mint shares to receiver
    /// @param assets Amount of assets to deposit
    /// @param receiver Share receiver
    /// @return shares Amount of shares received
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Deposit assets for receiver
    /// @param asset Asset
    /// @param assets Amount to deposit
    /// @param receiver Share recipient
    /// @return shares Amount of shares received
    function depositAsset(
        address asset,
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Helper to deposit assets for msg.sender upon referral specifying receiver
    /// @param assets Amount to deposit
    /// @param receiver receiver of deposit
    /// @param referralId id of referral
    /// @return shares Amount of shares received
    function depositWithReferral(
        uint256 assets,
        address receiver,
        string memory referralId
    ) external returns (uint256);

    /// @notice Helper to deposit particular asset for msg.sender upon referral
    /// @param asset Asset to deposit
    /// @param assets Amount to deposit
    /// @param receiver receiver of deposit
    /// @param referralId id of referral
    /// @return shares Amount of shares received
    function depositAssetWithReferral(
        address asset,
        uint256 assets,
        address receiver,
        string memory referralId
    ) external returns (uint256);

    //////////
    // Mint //
    //////////

    /// @notice Get max shares for mint
    /// @return shares Maximum mint amount
    function maxMint(
        address
    ) external view returns (uint256);

    /// @notice Preview assets for mint
    /// @param shares Amount to mint
    /// @return assets Amount of assets required
    function previewMint(
        uint256 shares
    ) external view returns (uint256);

    /// @notice Preview assets for mint
    /// @param asset Asset to deposit in
    /// @param shares Amount to mint
    /// @return assets Amount of assets required
    function previewMintForAsset(
        address asset,
        uint256 shares
    ) external view returns (uint256);

    /// @notice Mint exact number of shares to receiver and deposit in base asset
    /// @param shares Amount of shares to mint
    /// @param receiver Share receiver
    /// @return assets Amount of assets required
    function mint(
        uint256 shares,
        address receiver
    ) external returns (uint256 assets);

    /// @notice Mint shares for receiver with specific asset
    /// @param asset Asset to mint with
    /// @param shares Amount to mint
    /// @param receiver Share recipient
    /// @return assets Amount of assets required
    function mintWithAsset(
        address asset,
        uint256 shares,
        address receiver
    ) external returns (uint256 assets);

    //////////////
    // Withdraw //
    //////////////

    /// @notice Get max assets for withdraw
    /// @param controller Controller address
    /// @return assets Maximum withdraw amount
    function maxWithdraw(address controller) external view returns (uint256);

    /// @notice Get max assets for withdraw
    /// @param asset Asset
    /// @param controller Controller address
    /// @return assets Maximum withdraw amount
    function maxWithdrawForAsset(
        address asset,
        address controller
    ) external view returns (uint256);

    /// @notice Withdraw assets from fulfilled redeem requests
    /// @param assets Amount to withdraw
    /// @param receiver Asset recipient
    /// @param controller Controller address
    /// @return shares Amount of shares burned
    function withdraw(
        uint256 assets,
        address receiver,
        address controller
    ) external returns (uint256 shares);

    /// @notice Withdraw assets from fulfilled redeem requests
    /// @param asset Asset
    /// @param assets Amount to withdraw
    /// @param receiver Asset recipient
    /// @param controller Controller address
    /// @return shares Amount of shares burned
    function withdrawAsset(
        address asset,
        uint256 assets,
        address receiver,
        address controller
    ) external returns (uint256 shares);

    ////////////
    // Redeem //
    ////////////

    /// @notice Get max shares for redeem
    /// @param controller Controller address
    function maxRedeem(
        address controller
    ) external view returns (uint256);

    /// @notice Get max shares for redeem
    /// @param asset Asset
    /// @param controller Controller address
    /// @return shares Maximum redeem amount
    function maxRedeemForAsset(
        address asset,
        address controller
    ) external view returns (uint256);

    /// @notice Redeem shares from fulfilled requests
    /// @param shares Amount to redeem
    /// @param receiver Asset recipient
    /// @param controller Controller address
    /// @return assets Amount of assets received
    function redeem(
        uint256 shares,
        address receiver,
        address controller
    ) external returns (uint256 assets);

    /// @notice Redeem shares from fulfilled requests
    /// @param asset Asset
    /// @param shares Amount to redeem
    /// @param receiver Asset recipient
    /// @param controller Controller address
    /// @return assets Amount of assets received
    function redeemAsset(
        address asset,
        uint256 shares,
        address receiver,
        address controller
    ) external returns (uint256 assets);

    /////////////////////
    // Redeem requests //
    /////////////////////

    /// @notice Request redeem of shares
    /// @param asset Asset
    /// @param shares Amount to redeem
    /// @param controller Share recipient
    /// @param owner Share owner
    /// @param autoClaim If true, fulfilling this request auto-delivers assets to controller
    /// @return requestId Request identifier
    function requestRedeem(
        address asset,
        uint256 shares,
        address controller,
        address owner,
        bool autoClaim
    ) external returns (uint256 requestId);

    ////////////////////////
    // Redeem Fulfillment //
    ////////////////////////

    /// @notice Fulfill multiple redeem requests
    /// @param assets Array of assets
    /// @param shares Array of share amounts
    /// @param controllers Array of controllers
    /// @return Array of fulfilled amounts in requested asset
    function fulfillMultipleRedeems(
        address[] memory assets,
        uint256[] memory shares,
        address[] memory controllers
    ) external returns (uint256[] memory);

    ////////////////////////
    // Redeem Cancelation //
    ////////////////////////

    /// @notice Cancel redeem request for controller
    /// @param asset Asset
    /// @param controller Controller address
    /// @param receiver Share recipient
    /// @return shares Amount of shares canceled
    function cancelRedeemRequest(
        address asset,
        address controller,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Cancel redeem request for controller partially, for a specific amount of shares
    /// @param asset Asset
    /// @param shares Amount of shares to cancel
    /// @param controller Controller address
    /// @param receiver Share recipient
    function cancelRedeemRequestPartially(
        address asset,
        uint256 shares,
        address controller,
        address receiver
    ) external;

    /////////////////////
    // Admin Functions //
    /////////////////////

    /// @notice Propose an address update for the given key
    /// @param key The address key (see contract NatSpec for precomputed hashes)
    /// @param newAddress The new address being proposed
    function proposeAddressUpdate(bytes32 key, address newAddress) external;

    /// @notice Accept a previously proposed address update for the given key
    /// @param key The address key (see contract NatSpec for precomputed hashes)
    /// @param newAddress The new address to confirm
    /// @dev Pauses the vault on success
    function acceptAddressUpdate(bytes32 key, address newAddress) external;
}
