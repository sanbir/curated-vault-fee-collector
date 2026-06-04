// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

interface IOwnable {
    ////////////
    // Events //
    ////////////

    /// @dev Emitted when ownership is transferred.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    ////////////
    // Errors //
    ////////////

    /// @dev The caller account is not authorized to perform an operation.
    error OwnableUnauthorizedAccount(address account);

    /// @dev The owner is not a valid owner account. (eg. `address(0)`)
    error OwnableInvalidOwner(address owner);

    ///////////////
    // Functions //
    ///////////////

    /// @dev Returns the address of the current owner.
    function owner() external view returns (address);

    /// @dev Returns the address of the pending owner.
    function pendingOwner() external view returns (address);

    /// @dev Starts the ownership transfer of the contract to a new account. Replaces the pending transfer if there is one.
    /// Can only be called by the current owner.
    ///
    /// Setting `newOwner` to the zero address is allowed; this can be used to cancel an initiated ownership transfer.
    function transferOwnership(address newOwner) external;

    /// @dev The new owner accepts the ownership transfer.
    function acceptOwnership() external;
}
