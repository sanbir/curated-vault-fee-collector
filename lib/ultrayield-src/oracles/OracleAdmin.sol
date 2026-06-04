// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IUltraVaultOracle } from "src/interfaces/IUltraVaultOracle.sol";
import { IOwnable } from "src/interfaces/IOwnable.sol";

/// @title OracleAdmin
/// @notice Owner contract for managing UltraVaultOracle prices
/// @dev Allows owner and admin to update oracle prices
contract OracleAdmin is Ownable2Step {
    ////////////
    // Events //
    ////////////

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    ////////////
    // Errors //
    ////////////

    error NotAdminOrOwner();
    error ZeroOracleAddress();

    /////////////
    // Storage //
    /////////////

    /// @notice Oracle contract to manage
    IUltraVaultOracle public oracle;

    /// @notice Address authorized to update prices
    address public admin;

    /////////////////
    // Constructor //
    /////////////////

    /// @notice Initialize owner and oracle
    /// @param _oracle Oracle contract address
    /// @param _owner Owner address
    constructor(address _oracle, address _owner) Ownable(_owner) {
        require(_oracle != address(0), ZeroOracleAddress());
        oracle = IUltraVaultOracle(_oracle);
    }

    ///////////////////
    // Price Updates //
    ///////////////////

    /// @notice Set base/quote pair price
    /// @param base The base asset
    /// @param quote The quote asset
    /// @param price The price of the base in terms of the quote
    function setPrice(
        address base,
        address quote,
        uint256 price
    ) external onlyAdminOrOwner {
        oracle.setPrice(base, quote, price);
    }

    /// @notice Set multiple base/quote pair prices
    /// @param bases The base assets
    /// @param quotes The quote assets
    /// @param prices The prices of the bases in terms of the quotes
    /// @dev Array lengths must match
    function setPrices(
        address[] calldata bases,
        address[] calldata quotes,
        uint256[] calldata prices
    ) external onlyAdminOrOwner {
        oracle.setPrices(bases, quotes, prices);
    }

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
    ) external onlyAdminOrOwner {
        oracle.scheduleLinearPriceUpdate(
            base,
            quote,
            targetPrice,
            vestingTime
        );
    }

    /// @notice Set multiple base/quote pair prices with gradual changes
    /// @param bases The base assets
    /// @param quotes The quote assets
    /// @param prices The prices of the bases in terms of the quotes
    /// @param vestingTimes Vesting times over which the updates occur
    /// @dev Array lengths must match
    function scheduleLinearPricesUpdates(
        address[] calldata bases,
        address[] calldata quotes,
        uint256[] calldata prices,
        uint256[] calldata vestingTimes
    ) external onlyAdminOrOwner {
        oracle.scheduleLinearPricesUpdates(
            bases,
            quotes,
            prices,
            vestingTimes
        );
    }

    ////////////////////
    // Oracle Updates //
    ////////////////////

    function setOracle(
        address newOracle
    ) external onlyOwner {
        address currentOracle = address(oracle);
        if (newOracle != currentOracle) {
            emit OracleUpdated(currentOracle, newOracle);
            oracle = IUltraVaultOracle(newOracle);
        }
    }

    ////////////////////
    // Access Control //
    ////////////////////

    function setAdmin(address newAdmin) external onlyOwner {
        address currentAdmin = admin;
        if (newAdmin != currentAdmin) {
            emit AdminUpdated(currentAdmin, newAdmin);
            admin = newAdmin;
        }
    }

    function claimOracleOwnership() external onlyOwner {
        IOwnable(address(oracle)).acceptOwnership();
    }

    modifier onlyAdminOrOwner() {
        require(msg.sender == owner() || msg.sender == admin, NotAdminOrOwner());
        _;
    }
}
