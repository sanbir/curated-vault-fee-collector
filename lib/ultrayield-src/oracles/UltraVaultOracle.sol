// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IUltraVaultOracle, Price } from "src/interfaces/IUltraVaultOracle.sol";
import { IPriceSource } from "src/interfaces/IPriceSource.sol";

/// @title UltraVaultOracle
/// @notice Oracle for setting base/quote pair prices by permissioned entities
/// @dev Price safety and reliability handled by other contracts/infrastructure
contract UltraVaultOracle is Ownable2Step, IUltraVaultOracle {
    ///////////////
    // Constants //
    ///////////////

    string public constant name = "UltraVaultOracle";
    uint256 public constant MIN_VESTING_TIME = 23 hours;
    uint256 public constant MAX_VESTING_TIME = 7 days;
    uint8 internal constant PRICE_FEED_DECIMALS = 18;
    uint8 internal constant DEFAULT_DECIMALS = 18;

    /////////////
    // Storage //
    /////////////

    /// @dev Fetch price by [base][quote]
    mapping(address => mapping(address => Price)) internal _prices;

    /////////////////
    // Constructor //
    /////////////////

    constructor(address _owner) Ownable(_owner) {}

    /////////////////////
    // Set Price Logic //
    /////////////////////

    function prices(
        address base,
        address quote
    ) external view returns (Price memory) {
        return _prices[base][quote];
    }

    /// @notice Set base/quote pair price
    /// @param base The base asset
    /// @param quote The quote asset
    /// @param price The price of the base in terms of the quote
    function setPrice(
        address base,
        address quote,
        uint256 price
    ) external onlyOwner {
        _setPrice(base, quote, price);
    }

    /// @notice Set multiple base/quote pair prices
    /// @param bases The base assets
    /// @param quotes The quote assets
    /// @param priceArray The prices of the bases in terms of the quotes
    /// @dev Array lengths must match
    function setPrices(
        address[] memory bases,
        address[] memory quotes,
        uint256[] memory priceArray
    ) external onlyOwner {
        _checkLength(bases.length, quotes.length);
        _checkLength(bases.length, priceArray.length);

        for (uint256 i = 0; i < bases.length; i++) {
            _setPrice(bases[i], quotes[i], priceArray[i]);
        }
    }

    function _setPrice(
        address base,
        address quote,
        uint256 price
    ) internal {
        _prices[base][quote] = Price({
            price: price,
            targetPrice: 0,
            timestampForFullVesting: 0,
            lastUpdatedTimestamp: block.timestamp
        });
        emit PriceUpdated(base, quote, price, price, 0);
    }

    //////////////////////////
    // Vesting Price Update //
    //////////////////////////

    /// @notice Set base/quote pair price with gradual change
    /// @param base The base asset
    /// @param quote The quote asset
    /// @param targetPrice The target price of the base in terms of the quote
    /// @param vestingTime The time over which vesting would occur
    function scheduleLinearPriceUpdate(
        address base,
        address quote,
        uint256 targetPrice,
        uint256 vestingTime
    ) external onlyOwner {
        _scheduleLinearPriceUpdate(
            base,
            quote,
            targetPrice,
            vestingTime
        );
    }

    /// @notice Set multiple base/quote pair prices with gradual changes
    /// @param bases The base assets
    /// @param quotes The quote assets
    /// @param targetPrices The target prices of the bases in terms of the quotes
    /// @param vestingTimes The times over which vesting would occur
    /// @dev Array lengths must match
    function scheduleLinearPricesUpdates(
        address[] memory bases,
        address[] memory quotes,
        uint256[] memory targetPrices,
        uint256[] memory vestingTimes
    ) external onlyOwner {
        _checkLength(bases.length, quotes.length);
        _checkLength(bases.length, targetPrices.length);
        _checkLength(bases.length, vestingTimes.length);

        for (uint256 i = 0; i < bases.length; i++) {
            _scheduleLinearPriceUpdate(
                bases[i],
                quotes[i],
                targetPrices[i],
                vestingTimes[i]
            );
        }
    }

    function _scheduleLinearPriceUpdate(
        address base,
        address quote,
        uint256 targetPrice,
        uint256 vestingTime
    ) internal {
        // We are scheduling updates at least over 23 hours for operator convenience
        require(vestingTime >= MIN_VESTING_TIME && vestingTime <= MAX_VESTING_TIME, InvalidVestingTime(base, quote, vestingTime));

        uint256 price = _getCurrentPrice(base, quote);
        require(price != 0, ZeroVestingStartPrice(base, quote));
        uint256 timestampForFullVesting = block.timestamp + vestingTime;
        _prices[base][quote] = Price({
            price: price,
            targetPrice: targetPrice,
            timestampForFullVesting: timestampForFullVesting,
            lastUpdatedTimestamp: block.timestamp
        });

        emit PriceUpdated(
            base,
            quote,
            price,
            targetPrice,
            timestampForFullVesting
        );
    }

    ///////////////////////
    // Quote Calculation //
    ///////////////////////

    /// @notice Get current price for base/quote pair
    function getCurrentPrice(
        address base,
        address quote
    ) public view returns (uint256) {
        return _getCurrentPrice(base, quote);
    }

    function _getCurrentPrice(
        address base,
        address quote
    ) internal view returns (uint256) {
        Price memory price = _prices[base][quote];

        if (price.timestampForFullVesting == 0) {
            return price.price;
        }

        // The price if fully vested
        if (block.timestamp >= price.timestampForFullVesting) {
            return price.targetPrice;
        }

        bool increase = price.targetPrice >= price.price;
        uint256 diff;
        unchecked { diff = increase ? price.targetPrice - price.price : price.price - price.targetPrice; }

        uint256 timeElapsed = block.timestamp - price.lastUpdatedTimestamp;
        uint256 timeTotal = price.timestampForFullVesting - price.lastUpdatedTimestamp;
        uint256 change = diff * timeElapsed / timeTotal;
 
        return increase ? price.price + change : price.price - change;
    }

    /// @inheritdoc IPriceSource
    function getQuote(
        uint256 inAmount, 
        address base, 
        address quote
    ) external view returns (uint256) {
        return _getQuote(inAmount, base, quote);
    }

    function _getQuote(
        uint256 inAmount,
        address base,
        address quote
    ) internal view returns (uint256) {
        uint256 price = _getCurrentPrice(base, quote);
        require(price != 0, NoPriceData(base, quote));

        // Assets decimals are within [6, 18], enforced by UltraVaultRateProvider
        uint8 nominatorDecimals = _getDecimals(quote);
        uint8 denominatorDecimals = _getDecimals(base) + PRICE_FEED_DECIMALS;
        require(denominatorDecimals > nominatorDecimals, InvalidAssetsDecimals());
        uint8 diff;
        unchecked { diff = denominatorDecimals - nominatorDecimals; }
        return inAmount * price / 10 ** diff;
    }

    ///////////
    // Utils //
    ///////////

    /// @dev Check array lengths match
    function _checkLength(uint256 lengthA, uint256 lengthB) internal pure {
        require(lengthA == lengthB, InputLengthMismatch());
    }

    /// @notice Get asset decimals
    /// @param asset Token address
    /// @return The decimals of the asset
    /// @dev Returns decimals if found, otherwise 18 (default)
    function _getDecimals(address asset) internal view returns (uint8) {
        (bool success, bytes memory data) = 
            address(asset).staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return success && data.length == 32 ? abi.decode(data, (uint8)) : DEFAULT_DECIMALS;
    }
}
