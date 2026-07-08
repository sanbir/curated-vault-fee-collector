// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

interface IAddressUpdatableErrors {
    error AddressAlreadyInitialized();
    error ZeroAddressInput();
    error NoPendingUpdateProposal();
    error UpdateProposalAddressMismatch();
    error CannotAcceptProposalYet();
    error UpdateProposalExpired();
    error UnknownAddressKey(bytes32 key);
}
