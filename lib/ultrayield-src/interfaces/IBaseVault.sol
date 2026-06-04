// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import { IPausable } from "src/interfaces/IPausable.sol";
import { IERC7540Operator } from "ERC-7540/interfaces/IERC7540.sol";
import { IRedeemAccounting } from "src/interfaces/IRedeemAccounting.sol";
import { IUltraVaultRateProvider } from "src/interfaces/IUltraVaultRateProvider.sol";
import { IAccessControlDefaultAdminRules } from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC165 } from "@openzeppelin/contracts/interfaces/IERC165.sol";
import { AddressUpdateProposal } from "src/utils/AddressUpdates.sol";

interface IBaseVaultErrors {
    error NotOwner();
    error AccessDenied();
    error ZeroAssetAddress();
    error ZeroRateProviderAddress();
    error InputLengthMismatch();
    error CannotPreviewWithdrawInAsyncVault();
    error CannotPreviewRedeemInAsyncVault();
    error EmptyDeposit();
    error NothingToMint();
    error NothingToRedeem();
    error NothingToWithdraw();
    error NoPendingRedeem();
    error InsufficientBalance();
    error AssetNotSupported();
    error MissingRateProvider();
    error NoRateProviderProposed();
    error ProposedRateProviderMismatch();
    error CannotAcceptRateProviderYet();
    error RateProviderUpdateExpired();
}

interface IBaseVaultEvents {
    event RateProviderProposed(address indexed proposedProvider);
    event RateProviderUpdated(address indexed oldProvider, address indexed newProvider);
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
  IAccessControlDefaultAdminRules,
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

    /// @notice Returns the proposed rate provider
    /// @return proposedRateProvider The proposed rate provider
    function proposedRateProvider() external view returns (AddressUpdateProposal memory);

    /// @notice Converts assets to underlying
    /// @param _asset The asset to convert
    /// @param assets The amount of assets to convert
    /// @return baseAssets The amount of underlying received
    function convertToUnderlying(
        address _asset,
        uint256 assets
    ) external view returns (uint256 baseAssets);

    /// @notice Converts underlying to assets
    /// @param asset The asset to convert
    /// @param baseAssets The amount of underlying to convert
    /// @return assets The amount of assets received
    function convertFromUnderlying(
        address asset,
        uint256 baseAssets
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

    /// @notice Helper to deposit assets for msg.sender upon referral specifying receiver
    /// @param assets Amount to deposit
    /// @param receiver receiver of deposit
    /// @param referralId id of referral
    /// @return shares Amount of shares received
    function depositWithReferral(
        uint256 assets,
        address receiver,
        string calldata referralId
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
        string calldata referralId
    ) external returns (uint256);

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

    /// @notice Request redeem for msg.sender
    /// @param shares Amount to redeem
    /// @return requestId Request identifier
    function requestRedeem(uint256 shares) external returns (uint256 requestId);

    /// @notice Request redeem of shares
    /// @param shares Amount to redeem
    /// @param controller Share recipient
    /// @param owner Share owner
    /// @return requestId Request identifier
    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) external returns (uint256 requestId);

    /// @notice Request redeem of shares
    /// @param asset Asset
    /// @param shares Amount to redeem
    /// @param controller Share recipient
    /// @param owner Share owner
    /// @return requestId Request identifier
    function requestRedeemOfAsset(
        address asset,
        uint256 shares,
        address controller,
        address owner
    ) external returns (uint256 requestId);

    ////////////////////////
    // Redeem Fulfillment //
    ////////////////////////

    /// @notice Fulfill redeem request
    /// @param asset Asset
    /// @param shares Amount to redeem
    /// @param controller Controller address
    /// @return assets Amount of claimable assets
    function fulfillRedeem(
        address asset,
        uint256 shares,
        address controller
    ) external returns (uint256);

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
    /// @param controller Controller address
    /// @return shares Amount of shares canceled
    function cancelRedeemRequest(address controller) external returns (uint256 shares);

    /// @notice Cancel redeem request for controller
    /// @param controller Controller address
    /// @param receiver Share recipient
    /// @return shares Amount of shares canceled
    function cancelRedeemRequest(
        address controller,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Cancel redeem request for controller
    /// @param asset Asset
    /// @param controller Controller address
    /// @param receiver Share recipient
    /// @return shares Amount of shares canceled
    function cancelRedeemRequestOfAsset(
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

    /// @notice Propose new rate provider for owner acceptance after delay
    /// @param newRateProvider Address of the new rate provider
    function proposeRateProvider(address newRateProvider) external;

    /// @notice Accept proposed rate provider
    /// @param newRateProvider Address of the new rate provider
    function acceptProposedRateProvider(address newRateProvider) external;
} 
