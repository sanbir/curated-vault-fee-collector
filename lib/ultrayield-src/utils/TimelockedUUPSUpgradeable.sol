// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.TimelockedUUPSUpgradeable")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant TIMELOCKED_UUPS_STORAGE_LOCATION = 0x7afc453cc683fcfc27ce501db7dcd220398cd57313b5d865546460cea677ec00;

/// @title TimelockedUUPSUpgradeable
/// @notice UUPS upgradeable contract with timelock functionality for upgrades
/// @dev Inherits from UUPSUpgradeable and adds a 7-day minimum delay for upgrades
abstract contract TimelockedUUPSUpgradeable is UUPSUpgradeable {
    ////////////
    // Events //
    ////////////

    /// @notice Emitted when a new upgrade is proposed
    /// @param implementation The new implementation address
    /// @param data The data to execute a call after the upgrade
    /// @param executionTime The earliest time the upgrade can be executed
    event UpgradeProposed(
        address indexed implementation,
        bytes data,
        uint256 executionTime
    );

    /// @notice Emitted when a proposed upgrade is executed
    /// @param implementation The new implementation address
    /// @param data The data used to execute a call after the upgrade
    event UpgradeExecuted(address indexed implementation, bytes data);

    /// @notice Emitted when a proposed upgrade is cancelled
    /// @param implementation The implementation address for the cancelled upgrade
    /// @param dataHash The hash of the data to execute a call after the upgrade
    event UpgradeCancelled(address indexed implementation, bytes32 dataHash);

    ////////////
    // Errors //
    ////////////

    error NoUpgradeProposed();
    error PendingUpgradeAlreadyProposed();
    error UpgradeImplementationMismatch();
    error UpgradeDataMismatch();
    error UpgradeNotReady();

    ///////////////
    // Constants //
    ///////////////

    /// @notice Minimum delay for upgrades
    uint256 internal constant MIN_UPGRADE_DELAY = 7 days;

    /////////////
    // Storage //
    /////////////

    /// @dev Represents the single pending upgrade
    struct PendingUpgrade {
        // The proposed implementation address
        address implementation;
        // Hash of the data to execute a call after the upgrade
        bytes32 dataHash;
        // Earliest when the upgrade can be executed (0 if not proposed)
        uint256 executionTime;
    }

    /// @custom:storage-location erc7201:ultrayield.storage.TimelockedUUPSUpgradeable
    struct TimelockedUUPSStorage {
        PendingUpgrade pendingUpgrade;
    }

    function _getTimelockedUUPSStorage() internal pure returns (TimelockedUUPSStorage storage $) {
        assembly {
            $.slot := TIMELOCKED_UUPS_STORAGE_LOCATION
        }
    }

    //////////
    // Init //
    //////////

    function __TimelockedUUPSUpgradeable_init() internal onlyInitializing {
        __UUPSUpgradeable_init();
    }

    ////////////////////
    // View Functions //
    ////////////////////

    /// @notice Get the pending upgrade details
    /// @return implementation The implementation address (address(0) if none pending)
    /// @return dataHash The hash of call data for the upgrade
    /// @return executionTime The earliest time the upgrade can be executed (0 if none pending)
    function getPendingUpgrade() external view returns (address implementation, bytes32 dataHash, uint256 executionTime) {
        PendingUpgrade memory pendingUpgrade = _getTimelockedUUPSStorage().pendingUpgrade;
        return (
            pendingUpgrade.implementation,
            pendingUpgrade.dataHash,
            pendingUpgrade.executionTime
        );
    }

    /// @notice Check if an upgrade is ready to be executed
    /// @param implementation The implementation address
    /// @param data The call data for the upgrade
    /// @return ready True if the upgrade is ready to be executed
    function isUpgradeReady(
        address implementation,
        bytes memory data
    ) public view returns (bool) {
        PendingUpgrade memory pending = _getTimelockedUUPSStorage()
            .pendingUpgrade;
        require(pending.executionTime != 0, NoUpgradeProposed());
        require(pending.implementation == implementation, UpgradeImplementationMismatch());
        require(pending.dataHash == keccak256(data), UpgradeDataMismatch());
        return block.timestamp >= pending.executionTime;
    }

    ////////////////////////
    // Upgrade Management //
    ////////////////////////

    /// @notice Propose a new implementation for upgrade and data to execute a call after the upgrade
    /// @param newImplementation The address of the new implementation contract
    /// @param data The data to execute a call after the upgrade
    function proposeUpgrade(
        address newImplementation,
        bytes calldata data
    ) external onlyProxy {
        _authorizeUpgradeProposal();
        _proposeUpgrade(newImplementation, data);
    }

    function _proposeUpgrade(
        address newImplementation,
        bytes calldata data
    ) internal {
        PendingUpgrade storage pending = _getTimelockedUUPSStorage().pendingUpgrade;
        require(pending.executionTime == 0, PendingUpgradeAlreadyProposed());
        uint256 executionTime = block.timestamp + MIN_UPGRADE_DELAY;
        pending.implementation = newImplementation;
        pending.dataHash = keccak256(data);
        pending.executionTime = executionTime;

        emit UpgradeProposed(newImplementation, data, executionTime);
    }

    /// @notice Cancel the pending upgrade
    function cancelUpgrade() external onlyProxy {
        _authorizeUpgradeCancellation();
        _cancelUpgrade();
    }

    function _cancelUpgrade() internal {
        PendingUpgrade memory pending = _getTimelockedUUPSStorage().pendingUpgrade;
        require(pending.executionTime != 0, NoUpgradeProposed());

        emit UpgradeCancelled(pending.implementation, pending.dataHash);
        delete _getTimelockedUUPSStorage().pendingUpgrade;
    }

    ////////////////////
    // Access Control //
    ////////////////////

    function _authorizeUpgradeProposal() internal virtual;

    function _authorizeUpgradeCancellation() internal virtual;

    ////////////////////
    // UUPS Overrides //
    ////////////////////

    /// @notice Override upgradeToAndCall to enforce timelock validation
    /// @param newImplementation The new implementation address
    /// @param data The call data to execute
    /// @dev Validates timelock before allowing upgrade
    function upgradeToAndCall(
        address newImplementation,
        bytes memory data
    ) public payable virtual override {
        require(isUpgradeReady(newImplementation, data), UpgradeNotReady());

        delete _getTimelockedUUPSStorage().pendingUpgrade;
        super.upgradeToAndCall(newImplementation, data);

        emit UpgradeExecuted(newImplementation, data);
    }
}
