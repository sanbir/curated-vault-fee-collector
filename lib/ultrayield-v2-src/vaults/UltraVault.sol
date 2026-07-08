// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IPriceSource } from "uyv2/interfaces/IPriceSource.sol";
import { IUltraVaultEvents, IUltraVaultErrors } from "uyv2/interfaces/IUltraVault.sol";
import { Adjustment, Fees, PendingRedeem } from "uyv2/interfaces/Types.sol";
import { AddressUpdateProposal } from "uyv2/utils/AddressUpdates.sol";
import { ComplianceLib } from "uyv2/utils/ComplianceLib.sol";
import { FixedPointMathLib } from "uyv2/utils/FixedPointMathLib.sol";
import { BaseControlledAsyncRedeem, BaseControlledAsyncRedeemInitParams } from "uyv2/vaults/BaseControlledAsyncRedeem.sol";
import { COMPLIANCE_ROLE, OPERATOR_ROLE } from "uyv2/utils/Roles.sol";
import {
    FUNDS_HOLDER_KEY,
    ORACLE_KEY,
    INSTANT_REDEEM_EXITPOINT_KEY,
    UPGRADE_MODULE_KEY
} from "uyv2/utils/AddressKeys.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.UltraVault")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant ULTRA_VAULT_STORAGE_LOCATION = 0x4a2c313ed01a3f9b3ba2e7d99f5ac7985ad5a3c0482c127738b38df017064300;

/// @dev Initialization parameters for UltraVault
struct UltraVaultInitParams {
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
    // Fee recipient
    address feeRecipient;
    // Fee configuration
    Fees fees;
    // Oracle to use for pricing
    address oracle;
    // FundsHolder which will manage the assets
    address fundsHolder;
    // Exitpoint address for instant redeems
    address instantRedeemExitpoint;
    // External timelocked upgrade module
    address upgradeModule;
}

/// @title UltraVault
/// @notice ERC-7540 compliant async redeem vault with UltraVaultOracle pricing and multisig asset management
contract UltraVault is BaseControlledAsyncRedeem, IUltraVaultEvents, IUltraVaultErrors {
    using FixedPointMathLib for uint256;
    using Math for uint256;
    using SafeERC20 for IERC20;

    ///////////////
    // Constants //
    ///////////////

    uint256 internal constant ONE_YEAR = 365 * 24 * 60 * 60; // 31_536_000 seconds
    uint256 internal constant SCALE = 1e18; // Default scale
    // forge-lint: disable-next-line(unsafe-typecast)
    uint64 internal constant ONE_PERCENT = uint64(SCALE) / 100;
    uint64 internal constant MAX_PERFORMANCE_FEE = 30 * ONE_PERCENT; // 30%
    uint64 internal constant MAX_MANAGEMENT_FEE = 5 * ONE_PERCENT; // 5%
    uint64 internal constant MAX_WITHDRAWAL_FEE = ONE_PERCENT; // 1%
    uint64 internal constant MAX_INSTANT_REDEEM_PREMIUM = ONE_PERCENT / 2; // 0.5%

    uint256 internal constant FUNDS_HOLDER_TIMELOCK = 3 days;
    uint256 internal constant ORACLE_TIMELOCK = 3 days;
    uint256 internal constant INSTANT_REDEEM_EXITPOINT_TIMELOCK = 3 days;

    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.UltraVault
    struct UltraVaultStorage {
        address _fundsHolder; // Deprecated in V2
        IPriceSource _oracle; // Deprecated in V2
        AddressUpdateProposal _proposedFundsHolder; // Deprecated in V2
        AddressUpdateProposal _proposedOracle; // Deprecated in V2
        address feeRecipient;
        Fees fees;
    }

    /// @dev Returns the namespaced ERC-7201 storage struct for UltraVault
    function _getUltraVaultStorage() private pure returns (UltraVaultStorage storage $) {
        assembly {
            $.slot := ULTRA_VAULT_STORAGE_LOCATION
        }
    }

    //////////
    // Init //
    //////////

    /// @notice Disable implementation's initializer
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the vault; sets addresses, pauses, then initializes the base contract and fees
    /// @param params Initialization parameters struct
    function initialize(
        UltraVaultInitParams memory params
    ) external initializer {
        require(params.feeRecipient != address(0), ZeroFeeRecipientAddress());

        _initAddress(FUNDS_HOLDER_KEY, params.fundsHolder);
        _initAddress(ORACLE_KEY, params.oracle);
        _initAddress(INSTANT_REDEEM_EXITPOINT_KEY, params.instantRedeemExitpoint);
        _pause();
        
        // Calling at the end since we need oracle to be setup
        super.initialize(BaseControlledAsyncRedeemInitParams({
            owner: params.owner,
            asset: params.asset,
            name: params.name,
            symbol: params.symbol,
            rateProvider: params.rateProvider,
            upgradeModule: params.upgradeModule
        }));

        _getUltraVaultStorage().feeRecipient = params.feeRecipient;
        emit FeesRecipientUpdated(address(0), params.feeRecipient);
        _setFees(params.fees);
    }

    /// @notice V1 -> V2 migration hook
    /// @dev Copies only the live V1 contract addresses into the V2 address registry
    /// @dev Pending V1 address-update proposals are intentionally not migrated
    /// @param _instantRedeemExitpoint Address for the new instant redeem exitpoint (not present in V1)
    /// @param _upgradeModule Address of the external timelocked upgrade module (not present in V1)
    function initializeV2(
        address _instantRedeemExitpoint,
        address _upgradeModule
    ) external reinitializer(2) {
        _migrateBaseControlledAsyncRedeemStateFromV1();

        UltraVaultStorage storage $ = _getUltraVaultStorage();
        _migrateAddress(FUNDS_HOLDER_KEY, $._fundsHolder);
        _migrateAddress(ORACLE_KEY, address($._oracle));
        _initAddress(INSTANT_REDEEM_EXITPOINT_KEY, _instantRedeemExitpoint);
        _initAddress(UPGRADE_MODULE_KEY, _upgradeModule);

        _pause();
    }

    /////////////
    // Getters //
    /////////////

    /// @notice Get the funds holder address
    function fundsHolder() public view returns (address) {
        return _getCurrentAddress(FUNDS_HOLDER_KEY);
    }

    /// @notice Get the oracle address
    function oracle() public view returns (IPriceSource) {
        return IPriceSource(_getCurrentAddress(ORACLE_KEY));
    }

    /// @notice Get the instant redeem exitpoint address
    function instantRedeemExitpoint() public view returns (address) {
        return _getCurrentAddress(INSTANT_REDEEM_EXITPOINT_KEY);
    }

    ////////////////////////////
    // Initial Balances Setup //
    ////////////////////////////

    /// @notice Setup initial balances in the vault without depositing the funds
    /// @notice We expect the funds to be separately sent to funds holder
    /// @param users Array of users to setup balances
    /// @param shares Shares of respective users
    /// @dev Reverts if arrays length mismatch
    function setupInitialBalances(
        address[] memory users,
        uint256[] memory shares
    ) external onlyOwner {
        require(totalSupply() == 0, CannotSetBalancesInNonEmptyVault());
        require(users.length == shares.length, InputLengthMismatch());

        for (uint256 i; i < users.length; i++) {
            _mint(users[i], shares[i]);
        }
    }

    ////////////////
    // Accounting //
    ////////////////

    /// @notice Get total assets managed by fundsHolder
    function totalAssets() public view override returns (uint256) {
        uint256 totalShares = totalSupply();
        return convertToAssets(totalShares);
    }

    /// @notice Convert shares to underlying assets at the current oracle share price (rounded down)
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 sharePrice = _getSharePrice();
        return _optimizedConvertToAssets(shares, sharePrice);
    }

    /// @notice Convert underlying assets to shares at the current oracle share price (rounded down)
    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 sharePrice = _getSharePrice();
        return _optimizedConvertToShares(assets, sharePrice);
    }

    /// @dev Optimized function for converting shares to assets.
    /// @dev Uses pre-fetched share price. Always rounds down.
    function _optimizedConvertToAssets(
        uint256 shares,
        uint256 sharePrice
    ) internal pure returns (uint256 assets) {
        return shares.mulDivDown(sharePrice, SCALE);
    }

    /// @dev Optimized function for converting assets to shares.
    /// @dev Uses pre-fetched share price. Always rounds down.
    function _optimizedConvertToShares(
        uint256 assets,
        uint256 sharePrice
    ) internal pure returns (uint256 shares) {
        return assets.mulDivDown(SCALE, sharePrice);
    }

    /// @dev Oracle-based conversion used by ERC4626 preview/deposit/mint/withdraw/redeem.
    ///      Overriding these ensures the deposit path uses the same math as the public
    ///      convertToShares/convertToAssets (oracle-driven), avoiding a virtual-offset
    ///      mispricing on first deposit when the oracle is not 1:1.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return assets.mulDiv(SCALE, _getSharePrice(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return shares.mulDiv(_getSharePrice(), SCALE, rounding);
    }

    ////////////////////
    // Hook Overrides //
    ////////////////////

    /// @dev Hook for executing custom logic right after deposit/mint
    /// @dev Sends deposited funds to fundsHolder
    function _afterDeposit(
        address _asset, 
        uint256 assets, 
        uint256 /* shares */,
        address /* receiver */
    ) internal override {
        _ensureNotRestricted(msg.sender);
        IERC20(_asset).safeTransfer(fundsHolder(), assets);
    }

    /// @dev Hook for executing custom logic right before withdraw/redeem
    /// @dev Enforces compliance restrictions on receiver and controller
    function _beforeWithdraw(
        address /* _asset */, 
        uint256 /* assets */, 
        uint256 /* shares */,
        address receiver,
        address controller
    ) internal view override {
        _ensureNotRestricted(receiver);
        if (controller != receiver) _ensureNotRestricted(controller);
    }

    /// @dev Before fulfill redeem - transfer funds from fundsHolder to vault
    /// @dev "assets" will already be correct given the token user requested
    function _beforeFulfillRedeem(address _asset, uint256 assets, uint256) internal override {
        IERC20(_asset).safeTransferFrom(fundsHolder(), address(this), assets);
    }

    ////////////////////
    // Deposit & Mint //
    ////////////////////

    /// @dev Collects fees right before making a deposit
    function _depositAsset(
        address _asset,
        uint256 assets,
        address receiver
    ) internal override returns (uint256 shares) {
        _collectFees();
        shares = super._depositAsset(_asset, assets, receiver);
    }

    /// @dev Collects fees right before performing a mint
    function _mintWithAsset(
        address _asset,
        uint256 shares,
        address receiver
    ) internal override returns (uint256 assets) {
        _collectFees();
        assets = super._mintWithAsset(_asset, shares, receiver);
    }

    /// @dev Block restricted addresses from cancelling pending redeems
    /// @dev Receiver is gated by `_update` on the share transfer back from the vault.
    function _handleRedeemRequestCancelation(
        address _asset,
        uint256 shares,
        address controller,
        address receiver
    ) internal override {
        _ensureNotRestricted(controller);
        super._handleRedeemRequestCancelation(_asset, shares, controller, receiver);
    }

    ////////////////////
    // Instant Redeem //
    ////////////////////

    /// @notice Returns the available liquidity for instant redeem of a given asset
    /// @param _asset The asset address to check liquidity for
    /// @return liquidity The available liquidity (minimum of exitpoint balance and allowance to this vault)
    function getLiquidity(address _asset) public view returns (uint256 liquidity) {
        address exitpoint = instantRedeemExitpoint();
        uint256 balance = IERC20(_asset).balanceOf(exitpoint);
        uint256 allowed = IERC20(_asset).allowance(exitpoint, address(this));
        liquidity = balance < allowed ? balance : allowed;
    }

    /// @notice Returns the maximum shares a controller can instant-redeem for a given asset
    /// @dev Considers both the controller's share balance and available liquidity.
    ///      Liquidity bounds the gross payout (netAssets + fee are both pulled from the exitpoint),
    ///      so the shares are derived from liquidity directly and capped at controller balance.
    /// @param _asset The asset address to redeem for
    /// @param controller The address whose shares would be redeemed
    /// @return shares The maximum redeemable shares
    function maxInstantRedeem(
        address _asset,
        address controller
    ) external view returns (uint256 shares) {
        uint256 liquidity = getLiquidity(_asset);
        uint256 shareBalance = balanceOf(controller);
        if (liquidity == 0 || shareBalance == 0) {
            return 0;
        }
        uint256 maxUnderlyingAssets = convertToUnderlying(_asset, liquidity, Adjustment.UP);
        uint256 maxShares = convertToShares(maxUnderlyingAssets);
        return maxShares < shareBalance ? maxShares : shareBalance;
    }

    /// @notice Previews the net assets a receiver would get for instant-redeeming a given number of shares
    /// @dev Converts shares to gross assets via oracle, then deducts the additive instant redeem fee
    /// @param _asset The asset address to receive
    /// @param shares The number of shares to redeem
    /// @return assets The net asset amount after fee deduction
    function previewInstantRedeem(
        address _asset,
        uint256 shares
    ) public view returns (uint256) {
        (, , uint256 netAssets) = _previewInstantRedeem(_asset, shares);
        return netAssets;
    }

    /// @notice Instantly redeems shares for assets, bypassing the async redemption queue
    /// @dev Collects accrued fees, calculates additive fee (withdrawalFee + instantRedeemPremium),
    ///      burns shares from controller, transfers net assets to receiver, transfers fee to feeRecipient.
    ///      Reverts if insufficient liquidity in instantRedeemExitpoint.
    ///      Reverts with InstantRedeemSlippageExceeded if netAssets < minAssets.
    /// @param _asset The asset address to receive
    /// @param shares The number of shares to redeem
    /// @param minAssets Minimum net assets the receiver must receive; reverts InstantRedeemSlippageExceeded if not met. Pass 0 to disable.
    /// @param receiver The address to receive the net assets
    /// @param controller The address whose shares are burned
    /// @return assets The net asset amount transferred to receiver (after fee deduction)
    function instantRedeem(
        address _asset,
        uint256 shares,
        uint256 minAssets,
        address receiver,
        address controller
    ) external checkAccess(controller) whenNotPaused returns (uint256) {
        _ensureIsSupported(_asset);
        _ensureNotRestricted(receiver);
        if (controller != receiver) {
            _ensureNotRestricted(controller);
        }
        require(shares != 0, NothingToRedeem());
        require(balanceOf(controller) >= shares, InsufficientBalance());

        // Collect accrued fees before processing (consistent with deposits and fulfillRedeem)
        _collectFees();

        // Prepare instant redeem amounts
        (uint256 grossAssets, uint256 fee, uint256 netAssets) = _previewInstantRedeem(_asset, shares);
        require(netAssets != 0, NothingToWithdraw());

        // Slippage protection — bound caller's worst-case received amount
        if (netAssets < minAssets) {
            revert InstantRedeemSlippageExceeded(netAssets, minAssets);
        }

        // Check liquidity
        uint256 availableLiquidity = getLiquidity(_asset);
        if (grossAssets > availableLiquidity) {
            revert InsufficientLiquidity(_asset, grossAssets, availableLiquidity);
        }

        // Burn shares from controller
        _burn(controller, shares);

        // Transfer net assets to receiver
        address exitpoint = instantRedeemExitpoint();
        IERC20(_asset).safeTransferFrom(exitpoint, receiver, netAssets);

        // Transfer fee to feeRecipient
        if (fee > 0) {
            IERC20(_asset).safeTransferFrom(exitpoint, feeRecipient(), fee);
        }

        // Standard ERC-4626 event so generic indexers can track instant-redeem flows
        emit Withdraw(msg.sender, receiver, controller, netAssets, shares);
        emit InstantRedeem(controller, receiver, _asset, shares, netAssets, fee);

        return netAssets;
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
    ) external override onlyRole(OPERATOR_ROLE) returns (uint256[] memory) {
        // Check input length
        uint256 length = assets.length;
        require(length == shares.length && length == controllers.length, InputLengthMismatch());

        // Collect fees accrued to date
        _collectFees();

        // Prepare values for calculations
        uint256 totalShares;
        uint256 sharePrice = _getSharePrice();
        uint256 withdrawalFeeRate = getFees().withdrawalFee;
        uint256[] memory result = new uint256[](length);
        for (uint256 i; i < length; ) {
            // Resolve redeem amount in the requested asset
            address _asset = assets[i];
            uint256 _shares = shares[i];
            address _controller = controllers[i];
            uint256 underlyingAssets = _optimizedConvertToAssets(_shares, sharePrice);
            uint256 convertedAssets = convertFromUnderlying(_asset, underlyingAssets, Adjustment.DOWN);

            // Calculate and transfer withdrawal fee (in asset units)
            uint256 withdrawalFee = convertedAssets.mulDivDown(withdrawalFeeRate, SCALE);
            _transferWithdrawalFeeInAsset(_asset, withdrawalFee);

            // Fulfill redeem
            uint256 assetsFulfilled = _fulfillRedeem(_asset, convertedAssets - withdrawalFee, _shares, _controller);
            result[i] = assetsFulfilled;
            totalShares += _shares;

            unchecked { ++i; }
        }

        // Burn shares
        _burn(address(this), totalShares);

        return result;
    }

    /// @notice Cancel a user's pending redeem and return the locked shares to the controller's wallet
    /// @dev Bypasses compliance restrictions so the cleanup works even when the controller is blocklisted or frozen.
    /// @param _asset The asset originally requested for redemption
    /// @param controller The user whose pending redeem is being cancelled
    /// @return shares The amount of shares returned to the controller
    function cancelRedeemRequestByOperator(
        address _asset,
        address controller
    ) external onlyRole(OPERATOR_ROLE) returns (uint256 shares) {
        PendingRedeem memory pending = _getPendingRedeem(controller, _asset);
        shares = pending.shares;
        require(shares != 0, NoPendingRedeem());

        _consumePendingRedeem(controller, _asset, shares);

        // Call parent `_update` directly to bypass this contract's compliance gate; the controller may be restricted.
        super._update(address(this), controller, shares);

        emit RedeemRequestCanceled(controller, controller, shares);
    }

    /////////////////////
    // Address Updates //
    /////////////////////

    /// @inheritdoc BaseControlledAsyncRedeem
    function _timelockForKey(bytes32 key) internal pure override returns (uint256) {
        if (key == FUNDS_HOLDER_KEY) return FUNDS_HOLDER_TIMELOCK;
        if (key == ORACLE_KEY) return ORACLE_TIMELOCK;
        if (key == INSTANT_REDEEM_EXITPOINT_KEY) return INSTANT_REDEEM_EXITPOINT_TIMELOCK;
        return super._timelockForKey(key);
    }

    //////////
    // Fees //
    //////////

    /// @notice Get vault fee parameters
    function getFees() public view returns (Fees memory) {
        return _getUltraVaultStorage().fees;
    }

    /// @notice Get vault fee recipient
    function feeRecipient() public view returns (address) {
        return _getUltraVaultStorage().feeRecipient;
    }

    /// @notice Get total accrued fees
    function accruedFees() external view returns (uint256 managementFee, uint256 performanceFee) {
        Fees memory fees = getFees();
        Totals memory totals = _snapshotTotals();
        managementFee = _calculateAccruedManagementFee(fees, totals);
        performanceFee = _calculateAccruedPerformanceFee(fees, totals);
    }

    /// @notice Get the withdrawal fee
    function calculateWithdrawalFee(uint256 assets) external view returns (uint256) {
        return assets.mulDivDown(getFees().withdrawalFee, SCALE);
    }

    /// @notice Update vault's fee recipient
    /// @param newFeeRecipient New fee recipient
    /// @dev Collects pending fees before update
    function setFeeRecipient(address newFeeRecipient) public onlyOwner whenNotPaused {
        require(newFeeRecipient != address(0), ZeroFeeRecipientAddress());
        UltraVaultStorage storage $ = _getUltraVaultStorage();

        address oldFeeRecipient = $.feeRecipient;
        if (oldFeeRecipient != newFeeRecipient) {
            _collectFees();
            $.feeRecipient = newFeeRecipient;
            emit FeesRecipientUpdated(oldFeeRecipient, newFeeRecipient);
        }
    }

    /// @notice Update vault fees
    /// @param fees New fee configuration
    /// @dev Reverts if fees exceed limits (30% performance, 5% management, 1% withdrawal)
    /// @dev Collects pending fees before update
    function setFees(Fees memory fees) public onlyOwner whenNotPaused {
        _collectFees();
        _setFees(fees);
    }

    /// @notice Mint fees as shares to recipient
    /// @dev Updates fee-related variables
    function collectFees() external onlyOwner whenNotPaused {
        _collectFees();
    }

    ////////////////
    // Compliance //
    ////////////////

    /// @notice Get blocklist and freeze status for `account`
    /// @return blocked True if `account` is blocklisted
    /// @return frozen True if `account` is frozen
    function restrictionStatus(address account) external view returns (bool blocked, bool frozen) {
        ComplianceLib.Storage storage $ = ComplianceLib._getComplianceStorage();
        blocked = $.blocklisted[account];
        frozen = $.frozen[account];
    }

    /// @notice Add `account` to the blocklist
    function blocklist(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.blocklist(account);
    }

    /// @notice Remove `account` from the blocklist
    function unblocklist(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.unblocklist(account);
    }

    /// @notice Mark `account` as frozen
    function freeze(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.freeze(account);
    }

    /// @notice Unmark `account` as frozen
    function unfreeze(address account) external onlyRole(COMPLIANCE_ROLE) {
        ComplianceLib.unfreeze(account);
    }

    /// @notice Burn `amount` shares from `target`'s wallet balance.
    /// @dev Only affects `balanceOf(target)`; pending and claimable redeems are untouched.
    function forceBurn(address target, uint256 amount) external onlyRole(COMPLIANCE_ROLE) {
        _burn(target, amount);
        emit ForceBurned(target, amount);
    }

    /// @dev Reverts if `account` is blocklisted or frozen.
    /// @dev Returns early on `address(0)` so callers don't need to special-case mints/burns.
    function _ensureNotRestricted(address account) internal view {
        if (account == address(0)) return;
        ComplianceLib.Storage storage $ = ComplianceLib._getComplianceStorage();
        if ($.blocklisted[account]) revert AddressBlocklisted(account);
        if ($.frozen[account]) revert AddressFrozen(account);
    }

    /// @dev Gates share transfers and mints.
    /// @dev Burns (`to == 0`) skip the from-side check so `forceBurn` can destroy a restricted address's shares.
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0)) {
            _ensureNotRestricted(from);
        }
        _ensureNotRestricted(to);
        super._update(from, to, value);
    }

    //////////////////////
    // Internal helpers //
    //////////////////////

    /// @dev Struct wrapping total assets, supply and share value to optimize fee calculations
    struct Totals {
        uint256 totalAssets;
        uint256 totalShares;
        uint256 sharePrice;
    }

    /// @dev Validates fees against caps, refreshes the update timestamp, and preserves/seeds the highwater mark
    function _setFees(Fees memory newFees) internal {
        // Validate fees
        require(
            newFees.performanceFee <= MAX_PERFORMANCE_FEE &&
            newFees.managementFee <= MAX_MANAGEMENT_FEE &&
            newFees.withdrawalFee <= MAX_WITHDRAWAL_FEE &&
            newFees.instantRedeemPremium <= MAX_INSTANT_REDEEM_PREMIUM,
            InvalidFees()
        );

        newFees.lastUpdateTimestamp = uint64(block.timestamp);

        Fees memory currentFees = getFees();
        if (currentFees.highwaterMark == 0) {
            newFees.highwaterMark = 10 ** decimals();
        } else {
            newFees.highwaterMark = currentFees.highwaterMark;
        }
        _getUltraVaultStorage().fees = newFees;

        emit FeesUpdated(currentFees, newFees);
    }

    /// @dev Accrue management + performance fees, bump the highwater mark, and mint fee shares to `feeRecipient`
    function _collectFees() internal {
        // Prepare inputs for calculations
        Fees memory fees = getFees();
        Totals memory totals = _snapshotTotals();

        // Calculate fees
        uint256 managementFee = _calculateAccruedManagementFee(fees, totals);
        uint256 performanceFee = _calculateAccruedPerformanceFee(fees, totals);
        uint256 totalFeesInAssets = managementFee + performanceFee;

        // Update highwater mark
        if (totals.sharePrice > fees.highwaterMark) {
            _getUltraVaultStorage().fees.highwaterMark = totals.sharePrice;
        }
        // Collect fees as shares if non-zero
        if (totalFeesInAssets > 0) {
            // Update timestamp
            _getUltraVaultStorage().fees.lastUpdateTimestamp = uint64(block.timestamp);

            // Convert fees to shares
            uint256 feesInShares = _optimizedConvertToShares(totalFeesInAssets, totals.sharePrice);

            // Mint shares to fee recipient
            _mint(feeRecipient(), feesInShares);

            emit FeesCollected(
                feesInShares, 
                managementFee, 
                performanceFee, 
                totals.totalAssets, 
                totals.totalShares, 
                totals.sharePrice
            );
        }
    }

    /// @dev Snapshots share price, total supply, and total assets into a single struct for fee math
    function _snapshotTotals() internal view returns (Totals memory) {
        uint256 sharePrice = _getSharePrice();
        uint256 totalShares = totalSupply();
        return Totals({
            totalAssets: _optimizedConvertToAssets(totalShares, sharePrice),
            totalShares: totalShares,
            sharePrice: sharePrice
        });
    }

    /// @notice Calculate accrued performance fee
    /// @return accruedPerformanceFee Fee amount in asset token
    /// @dev Based on high water mark value
    function _calculateAccruedPerformanceFee(
        Fees memory fees,
        Totals memory totals
    ) internal view returns (uint256) {
        uint256 performanceFee = fees.performanceFee;
        if (performanceFee == 0 || totals.sharePrice <= fees.highwaterMark) {
            return 0;
        }
        return performanceFee.mulDivDown(
            (totals.sharePrice - fees.highwaterMark) * totals.totalShares,
            (10 ** (18 + decimals()))
        );
    }

    /// @notice Calculate accrued management fee
    /// @return accruedManagementFee Fee amount in asset token
    /// @dev Annualized per minute, based on 525_600 minutes or 31_536_000 seconds per year
    function _calculateAccruedManagementFee(Fees memory fees, Totals memory totals) internal view returns (uint256) {
        uint256 managementFee = fees.managementFee;
        if (managementFee == 0) {
            return 0;
        }
        uint256 timePassed = block.timestamp - fees.lastUpdateTimestamp;
        return managementFee.mulDivDown(totals.totalAssets * timePassed, ONE_YEAR) / SCALE;
    }

    /// @dev Returns the current share price from the oracle (underlying assets per share, scaled by SCALE)
    function _getSharePrice() internal view returns (uint256) {
        return oracle().currentSharePrice();
    }

    /// @dev Computes instant redeem amounts for `shares` paid out in `_asset`
    /// @return grossAssets Assets owed before fees (rounded down on the underlying->asset conversion)
    /// @return fee Additive fee in asset units: withdrawalFee + instantRedeemPremium applied to grossAssets
    /// @return netAssets grossAssets minus fee, transferred to the receiver
    function _previewInstantRedeem(address _asset, uint256 shares)
        internal
        view
        returns (uint256 grossAssets, uint256 fee, uint256 netAssets)
    {
        uint256 underlyingAssets = convertToAssets(shares);
        grossAssets = convertFromUnderlying(_asset, underlyingAssets, Adjustment.DOWN);
        Fees memory fees = getFees();
        fee = grossAssets.mulDivDown(fees.withdrawalFee + fees.instantRedeemPremium, SCALE);
        netAssets = grossAssets - fee;
    }

    /// @notice Transfer withdrawal fee to fee recipient
    /// @param _asset Asset to transfer
    /// @param fee Amount to transfer
    function _transferWithdrawalFeeInAsset(
        address _asset,
        uint256 fee
    ) internal {
        if (fee > 0) {
            // Transfer the fee from the fundsHolder to the fee recipient
            IERC20(_asset).safeTransferFrom(fundsHolder(), feeRecipient(), fee);
            emit WithdrawalFeeCollected(fee);
        }
    }
}
