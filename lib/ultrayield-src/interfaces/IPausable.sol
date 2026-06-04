// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

interface IPausable {
    /// @notice Returns the paused status of the vault
    /// @return paused The paused status of the vault
    function paused() external view returns (bool);

    /// @notice Pauses the contract
    function pause() external;

    /// @notice Unpauses the contract
    function unpause() external;
}
