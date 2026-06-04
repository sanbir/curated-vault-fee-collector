// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IPriceSource } from "src/interfaces/IPriceSource.sol";
import { Fees, IUltraVaultEvents, IUltraVaultErrors } from "src/interfaces/IUltraVault.sol";
import { AddressUpdateProposal } from "src/utils/AddressUpdates.sol";
import { FixedPointMathLib } from "src/utils/FixedPointMathLib.sol";
import { BaseControlledAsyncRedeem, BaseControlledAsyncRedeemInitParams } from "src/vaults/BaseControlledAsyncRedeem.sol";
import { OPERATOR_ROLE } from "src/utils/Roles.sol";

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
}

/// @title UltraVault
/// @notice ERC-7540 compliant async redeem vault with UltraVaultOracle pricing and multisig asset management
contract UltraVault is BaseControlledAsyncRedeem, IUltraVaultEvents, IUltraVaultErrors {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    ///////////////
    // Constants //
    ///////////////

    uint256 internal constant ONE_YEAR = 365 * 24 * 60 * 60; // 31_536_000 seconds
    uint256 internal constant ONE_UNIT = 1e18; // Default scale
    uint64 internal constant ONE_PERCENT = uint64(ONE_UNIT) / 100;
    uint64 internal constant MAX_PERFORMANCE_FEE = 30 * ONE_PERCENT; // 30%
    uint64 internal constant MAX_MANAGEMENT_FEE = 5 * ONE_PERCENT; // 5%
    uint64 internal constant MAX_WITHDRAWAL_FEE = ONE_PERCENT; // 1%

    /////////////
    // Storage //
    /////////////

    /// @custom:storage-location erc7201:ultrayield.storage.UltraVault
    struct UltraVaultStorage {
        address fundsHolder;
        IPriceSource oracle;
        AddressUpdateProposal proposedFundsHolder;
        AddressUpdateProposal proposedOracle;
        address feeRecipient;
        Fees fees;
    }

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

    /// @param params Initialization parameters struct
    function initialize(
        UltraVaultInitParams memory params
    ) external initializer {
        require(params.fundsHolder != address(0), ZeroFundsHolderAddress());
        require(params.oracle != address(0), ZeroOracleAddress());
        require(params.feeRecipient != address(0), ZeroFeeRecipientAddress());

        UltraVaultStorage storage $ = _getUltraVaultStorage();
        $.fundsHolder = params.fundsHolder;
        $.oracle = IPriceSource(params.oracle);
        _pause();
        
        // Calling at the end since we need oracle to be setup
        super.initialize(BaseControlledAsyncRedeemInitParams({
            owner: params.owner,
            asset: params.asset,
            name: params.name,
            symbol: params.symbol,
            rateProvider: params.rateProvider
        }));

        $.feeRecipient = params.feeRecipient;
        emit FeesRecipientUpdated(address(0), params.feeRecipient);
        _setFees(params.fees);
    }

    /////////////
    // Getters //
    /////////////

    /// @notice Get the funds holder address
    function fundsHolder() public view returns (address) {
        return _getUltraVaultStorage().fundsHolder;
    }

    /// @notice Get the oracle address
    function oracle() public view returns (IPriceSource) {
        return _getUltraVaultStorage().oracle;
    }

    /// @notice Get the proposed funds holder
    function proposedFundsHolder() public view returns (address, uint256) {
        AddressUpdateProposal memory proposal = _getUltraVaultStorage().proposedFundsHolder;
        return (proposal.addr, proposal.timestamp);
    }

    /// @notice Get the proposed oracle
    function proposedOracle() public view returns (address, uint256) {
        AddressUpdateProposal memory proposal = _getUltraVaultStorage().proposedOracle;
        return (proposal.addr, proposal.timestamp);
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
        return oracle().getQuote(totalSupply(), share(), asset());
    }

    ////////////////////
    // Hook Overrides //
    ////////////////////

    /// @dev After deposit hook - collect fees and send funds to fundsHolder
    function afterDeposit(address _asset, uint256 assets, uint256) internal override {
        IERC20(_asset).safeTransfer(fundsHolder(), assets);
    }

    /// @dev Before fulfill redeem - transfer funds from fundsHolder to vault
    /// @dev "assets" will already be correct given the token user requested
    function beforeFulfillRedeem(address _asset, uint256 assets, uint256) internal override {
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

    ////////////////////////
    // Redeem Fulfillment //
    ////////////////////////

    /// @notice Fulfill redeem request
    /// @param _asset Asset
    /// @param shares Amount to redeem
    /// @param controller Controller address
    /// @return assets Amount of claimable assets
    function fulfillRedeem(
        address _asset,
        uint256 shares,
        address controller
    ) external override onlyRole(OPERATOR_ROLE) returns (uint256 assets) {
        // Collect fees accrued to date
        _collectFees();
        
        // Convert shares to underlying assets, then to asset units
        uint256 underlyingAssets = convertToAssets(shares);
        assets = _convertFromUnderlying(_asset, underlyingAssets);
        
        // Calculate the withdrawal incentive fee directly in asset units
        uint256 withdrawalFee = assets.mulDivDown(getFees().withdrawalFee, ONE_UNIT);

        // Fulfill request with asset units (base contract expects asset units)
        uint256 withdrawalAmount = assets - withdrawalFee;
        _fulfillRedeem(_asset, withdrawalAmount, shares, controller);

        // Burn shares
        _burn(address(this), shares);

        // Collect withdrawal fee in asset units
        _transferWithdrawalFeeInAsset(_asset, withdrawalFee);

        // Return the amount in asset units for consistency with base contract
        return withdrawalAmount;
    }

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
        uint256 _totalAssets = totalAssets();
        uint256 _totalSupply = totalSupply();
        uint256 withdrawalFeeRate = getFees().withdrawalFee;
        uint256[] memory result = new uint256[](length);
        for (uint256 i; i < length; ) {
            // Resolve redeem amount in the requested asset
            address _asset = assets[i];
            uint256 _shares = shares[i];
            address _controller = controllers[i];
            uint256 underlyingAssets = _optimizedConvertToAssets(_shares, _totalAssets, _totalSupply);
            uint256 convertedAssets = _convertFromUnderlying(_asset, underlyingAssets);

            // Calculate and transfer withdrawal fee (in asset units)
            uint256 withdrawalFee = convertedAssets.mulDivDown(withdrawalFeeRate, ONE_UNIT);
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

    //////////////////////////
    // Funds Holder Updates //
    //////////////////////////

    /// @notice Propose fundsHolder change, can be accepted after delay
    /// @param newFundsHolder New fundsHolder address
    /// @dev changing the holder should be used only in case of multisig upgrade after funds transfer
    function proposeFundsHolder(address newFundsHolder) external onlyOwner {
        require(newFundsHolder != address(0), ZeroFundsHolderAddress());

        _getUltraVaultStorage().proposedFundsHolder = AddressUpdateProposal({
            addr: newFundsHolder,
            timestamp: uint96(block.timestamp)
        });

        emit FundsHolderProposed(newFundsHolder);
    }

    /// @notice Accept proposed fundsHolder
    /// @dev Pauses vault to ensure oracle setup and prevent deposits with faulty prices
    /// @dev Oracle must be switched before unpausing
    function acceptFundsHolder(address newFundsHolder) external onlyOwner {
        (address proposedHolder, uint256 proposalTimestamp) = proposedFundsHolder();
        require(proposedHolder != address(0), NoPendingFundsHolderUpdate());
        require(proposedHolder == newFundsHolder, ProposedFundsHolderMismatch());
        require(block.timestamp >= proposalTimestamp + ADDRESS_UPDATE_TIMELOCK, CannotAcceptFundsHolderYet());
        require(block.timestamp <= proposalTimestamp + MAX_ADDRESS_UPDATE_WAIT, FundsHolderUpdateExpired());

        emit FundsHolderChanged(fundsHolder(), newFundsHolder);

        UltraVaultStorage storage $ = _getUltraVaultStorage();
        $.fundsHolder = newFundsHolder;
        delete $.proposedFundsHolder;

        // Pause to manually check the setup by operators
        _pause();
    }

    ////////////////////
    // Oracle Updates //
    ////////////////////

    /// @notice Propose new oracle for owner acceptance after delay
    /// @param newOracle Address of the new oracle
    function proposeOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), ZeroOracleAddress());

        _getUltraVaultStorage().proposedOracle = AddressUpdateProposal({
            addr: newOracle,
            timestamp: uint96(block.timestamp)
        });

        emit OracleProposed(newOracle);
    }

    /// @notice Accept proposed oracle
    /// @dev Pauses vault to ensure oracle setup and prevent deposits with faulty prices
    /// @dev Oracle must be switched before unpausing
    function acceptProposedOracle(address newOracle) external onlyOwner {
        (address pendingOracle, uint256 proposalTimestamp) = proposedOracle();
        require(pendingOracle != address(0), NoOracleProposed());
        require(pendingOracle == newOracle, ProposedOracleMismatch());
        require(block.timestamp >= proposalTimestamp + ADDRESS_UPDATE_TIMELOCK, CannotAcceptOracleYet());
        require(block.timestamp <= proposalTimestamp + MAX_ADDRESS_UPDATE_WAIT, OracleUpdateExpired());

        emit OracleUpdated(address(oracle()), newOracle);

        UltraVaultStorage storage $ = _getUltraVaultStorage();
        $.oracle = IPriceSource(newOracle);
        delete $.proposedOracle;

        // Pause to manually check the setup by operators
        _pause();
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
    function accruedFees() external view returns (uint256) {
        Fees memory fees = getFees();
        Totals memory totals = _snapshotTotals();
        return _calculateAccruedPerformanceFee(fees, totals) + _calculateAccruedManagementFee(fees, totals);
    }

    /// @notice Get accrued management fees
    function accruedManagementFees() external view returns (uint256) {
        Fees memory fees = getFees();
        Totals memory totals = _snapshotTotals();
        return _calculateAccruedManagementFee(fees, totals);
    }

    /// @notice Get accrued performance fees
    function accruedPerformanceFees() external view returns (uint256) {
        Fees memory fees = getFees();
        Totals memory totals = _snapshotTotals();
        return _calculateAccruedPerformanceFee(fees, totals);
    }

    /// @notice Get the withdrawal fee
    function calculateWithdrawalFee(uint256 assets) external view returns (uint256) {
        return assets.mulDivDown(getFees().withdrawalFee, ONE_UNIT);
    }

    /// @notice Update vault's fee recipient
    /// @param newFeeRecipient New fee recipient
    /// @dev Collects pending fees before update
    function setFeeRecipient(address newFeeRecipient) public onlyOwner whenNotPaused {
        require(newFeeRecipient != address(0), ZeroFeeRecipientAddress());

        address currentFeeRecipient = feeRecipient();
        if (currentFeeRecipient != newFeeRecipient) {
            _collectFees();
            _getUltraVaultStorage().feeRecipient = newFeeRecipient;
            emit FeesRecipientUpdated(currentFeeRecipient, newFeeRecipient);
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

    ////////////////////////
    // Internal functions //
    ////////////////////////

    /// @dev Struct wrapping total assets, supply and share value to optimize fee calculations
    struct Totals {
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 shareValue;
    }

    function _setFees(Fees memory fees) internal {
        require(
            fees.performanceFee <= MAX_PERFORMANCE_FEE &&
            fees.managementFee <= MAX_MANAGEMENT_FEE &&
            fees.withdrawalFee <= MAX_WITHDRAWAL_FEE,
            InvalidFees()
        );

        fees.lastUpdateTimestamp = uint64(block.timestamp);

        Fees memory currentFees = getFees();
        if (currentFees.highwaterMark == 0) {
            fees.highwaterMark = 10 ** IERC20Metadata(asset()).decimals();
        } else {
            fees.highwaterMark = currentFees.highwaterMark;
        }
        _getUltraVaultStorage().fees = fees;

        emit FeesUpdated(currentFees, fees);
    }

    function _collectFees() internal {
        // Prepare inputs for calculations
        Fees memory fees = getFees();
        Totals memory totals = _snapshotTotals();

        // Calculate fees
        uint256 managementFee = _calculateAccruedManagementFee(fees, totals);
        uint256 performanceFee = _calculateAccruedPerformanceFee(fees, totals);
        uint256 totalFeesInAssets = managementFee + performanceFee;

        // Update highwater mark
        if (totals.shareValue > fees.highwaterMark) {
            _getUltraVaultStorage().fees.highwaterMark = totals.shareValue;
        }
        // Collect fees as shares if non-zero
        if (totalFeesInAssets > 0) {
            // Update timestamp
            _getUltraVaultStorage().fees.lastUpdateTimestamp = uint64(block.timestamp);

            // Convert fees to shares
            uint256 feesInShares = _optimizedConvertToShares(totalFeesInAssets, totals.totalAssets, totals.totalSupply);

            // Mint shares to fee recipient
            _mint(feeRecipient(), feesInShares);

            emit FeesCollected(feesInShares, managementFee, performanceFee);
        }
    }

    function _snapshotTotals() internal view returns (Totals memory) {
        uint256 _totalAssets = totalAssets();
        uint256 _totalSupply = totalSupply();
        return Totals({
            totalAssets: _totalAssets,
            totalSupply: _totalSupply,
            shareValue: _optimizedConvertToAssets(10 ** decimals(), _totalAssets, _totalSupply)
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
        if (performanceFee == 0 || totals.shareValue <= fees.highwaterMark) {
            return 0;
        }
        return performanceFee.mulDivDown(
            (totals.shareValue - fees.highwaterMark) * totals.totalSupply,
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
        return managementFee.mulDivDown(totals.totalAssets * timePassed, ONE_YEAR) / ONE_UNIT;
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
