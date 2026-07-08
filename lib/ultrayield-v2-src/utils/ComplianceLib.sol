// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IComplianceEvents } from "uyv2/interfaces/ICompliance.sol";

// keccak256(abi.encode(uint256(keccak256("ultrayield.storage.Compliance")) - 1)) & ~bytes32(uint256(0xff));
bytes32 constant COMPLIANCE_STORAGE_LOCATION = 0xbe508e3cf19f76c02ce3ef084fcdeeaf41d8436cf97d44f5a26356dbb6809600;

/// @title ComplianceLib
/// @notice External library for compliance state mutations and reads
/// @dev Storage matches `Compliance`'s ERC-7201 namespace (`ultrayield.storage.Compliance`)
/// @dev Public functions are deployed separately and called via DELEGATECALL
library ComplianceLib {
    /// @custom:storage-location erc7201:ultrayield.storage.Compliance
    struct Storage {
        mapping(address => bool) blocklisted;
        mapping(address => bool) frozen;
    }

    function _getComplianceStorage() internal pure returns (Storage storage $) {
        assembly {
            $.slot := COMPLIANCE_STORAGE_LOCATION
        }
    }

    ///////////////
    // Write Fns //
    ///////////////

    function blocklist(address account) external {
        Storage storage $ = _getComplianceStorage();
        if (!$.blocklisted[account]) {
            $.blocklisted[account] = true;
            emit IComplianceEvents.Blocklisted(account);
        }
    }

    function unblocklist(address account) external {
        Storage storage $ = _getComplianceStorage();
        if ($.blocklisted[account]) {
            $.blocklisted[account] = false;
            emit IComplianceEvents.Unblocklisted(account);
        }
    }

    function freeze(address account) external {
        Storage storage $ = _getComplianceStorage();
        if (!$.frozen[account]) {
            $.frozen[account] = true;
            emit IComplianceEvents.Frozen(account);
        }
    }

    function unfreeze(address account) external {
        Storage storage $ = _getComplianceStorage();
        if ($.frozen[account]) {
            $.frozen[account] = false;
            emit IComplianceEvents.Unfrozen(account);
        }
    }
}
