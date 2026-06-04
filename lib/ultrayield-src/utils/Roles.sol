// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
bytes32 constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN_ROLE");
bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
