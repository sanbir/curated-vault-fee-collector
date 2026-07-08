// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { UPGRADER_ROLE } from "uyv2/utils/Roles.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
}

/// @title TimelockedUpgradeModule
/// @notice External upgrade gate for a UUPS proxy
/// @dev Queues a pending upgrade for `MIN_UPGRADE_DELAY` and then forwards `upgradeToAndCall` to the vault. 
/// @dev Vault must register this module's address and verify `msg.sender == upgradeModule()` in its `_authorizeUpgrade` hook.
contract TimelockedUpgradeModule {
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

    error Unauthorized();
    error ZeroVaultAddress();
    error NoUpgradeProposed();
    error PendingUpgradeAlreadyProposed();
    error UpgradeImplementationMismatch();
    error UpgradeDataMismatch();
    error UpgradeNotReady();

    ///////////////
    // Constants //
    ///////////////

    /// @notice Minimum delay between proposing and executing an upgrade
    uint256 public constant MIN_UPGRADE_DELAY = 7 days;

    ///////////////
    // Immutable //
    ///////////////

    /// @notice The vault this module is bound to
    address public immutable vault;

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

    /// @notice The currently pending upgrade
    PendingUpgrade public pendingUpgrade;

    /////////////////
    // Constructor //
    /////////////////

    constructor(address _vault) {
        require(_vault != address(0), ZeroVaultAddress());
        vault = _vault;
    }

    ///////////////////
    // Authorization //
    ///////////////////

    modifier onlyUpgrader() {
        require(IAccessControl(vault).hasRole(UPGRADER_ROLE, msg.sender), Unauthorized());
        _;
    }

    ////////////////////////
    // Upgrade Management //
    ////////////////////////

    /// @notice Propose a new implementation for the bound vault
    /// @param newImplementation The address of the new implementation contract
    /// @param data The data to execute a call after the upgrade
    function proposeUpgrade(
        address newImplementation,
        bytes calldata data
    ) external onlyUpgrader {
        require(pendingUpgrade.executionTime == 0, PendingUpgradeAlreadyProposed());
        uint256 executionTime = block.timestamp + MIN_UPGRADE_DELAY;
        pendingUpgrade = PendingUpgrade({
            implementation: newImplementation,
            dataHash: keccak256(data),
            executionTime: executionTime
        });

        emit UpgradeProposed(newImplementation, data, executionTime);
    }

    /// @notice Cancel the pending upgrade
    function cancelUpgrade() external onlyUpgrader {
        PendingUpgrade memory pending = pendingUpgrade;
        require(pending.executionTime != 0, NoUpgradeProposed());

        delete pendingUpgrade;
        emit UpgradeCancelled(pending.implementation, pending.dataHash);
    }

    /// @notice Execute the pending upgrade after the timelock has elapsed
    /// @param implementation Implementation address (must match the proposed one)
    /// @param data Call data (must hash to the proposed dataHash)
    function executeUpgrade(
        address implementation,
        bytes calldata data
    ) external onlyUpgrader {
        PendingUpgrade memory pending = pendingUpgrade;
        require(pending.executionTime != 0, NoUpgradeProposed());
        require(pending.implementation == implementation, UpgradeImplementationMismatch());
        require(pending.dataHash == keccak256(data), UpgradeDataMismatch());
        require(block.timestamp >= pending.executionTime, UpgradeNotReady());

        delete pendingUpgrade;
        IUUPSUpgradeable(vault).upgradeToAndCall(implementation, data);

        emit UpgradeExecuted(implementation, data);
    }

    ////////////////////
    // View Functions //
    ////////////////////

    /// @notice Check if an upgrade is ready to be executed
    /// @param implementation The implementation address
    /// @param data The call data for the upgrade
    /// @return True if the upgrade is ready to be executed
    function isUpgradeReady(
        address implementation,
        bytes calldata data
    ) external view returns (bool) {
        PendingUpgrade memory pending = pendingUpgrade;
        require(pending.executionTime != 0, NoUpgradeProposed());
        require(pending.implementation == implementation, UpgradeImplementationMismatch());
        require(pending.dataHash == keccak256(data), UpgradeDataMismatch());
        return block.timestamp >= pending.executionTime;
    }
}
