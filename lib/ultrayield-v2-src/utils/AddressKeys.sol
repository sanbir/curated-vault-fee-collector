// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/// @dev Keys for timelocked address slots managed via `AddressUpdatable`.

/// @dev keccak256("rateProvider") = 0x9ae0efdc36eddfdabb79f8c96fa751fc831c1d3e0cdac57a0d250e4786bad23e
bytes32 constant RATE_PROVIDER_KEY = keccak256("rateProvider");

/// @dev keccak256("upgradeModule") = 0x4aa58e3031b775f133ff414650c5d3bf825536d4413cb4128e3e2d6a32738222
bytes32 constant UPGRADE_MODULE_KEY = keccak256("upgradeModule");

/// @dev keccak256("fundsHolder") = 0x9a7735ca78992cc02832623b2d2585ac0e4dcdf296c8fbd32eabc9244e853e07
bytes32 constant FUNDS_HOLDER_KEY = keccak256("fundsHolder");

/// @dev keccak256("oracle") = 0x89cbf5af14e0328a3cd3a734f92c3832d729d431da79b7873a62cbeebd37beb6
bytes32 constant ORACLE_KEY = keccak256("oracle");

/// @dev keccak256("instantRedeemExitpoint") = 0x48f088031e9e3abd14d32c601c02e21d4c8d0792bd677a8a5d6821b83ce55ca4
bytes32 constant INSTANT_REDEEM_EXITPOINT_KEY = keccak256("instantRedeemExitpoint");
