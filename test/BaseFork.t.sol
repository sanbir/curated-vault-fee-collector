// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";

/// @notice Shared mainnet-fork scaffolding. No mocks: tests run against live protocol bytecode
///         (or, for UltraYield, against the real UltraYield source deployed onto the fork).
abstract contract BaseFork is Test {
    /// @dev Recent mainnet block (> fLiteUSD deploy block ~24.62M). Override via env if desired.
    uint256 internal constant FORK_BLOCK = 25_230_000;

    // Canonical mainnet assets.
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function _fork() internal {
        // Default fallback is an archive-capable public endpoint (serves historical state at FORK_BLOCK).
        // Override with your own MAINNET_RPC_URL for speed/reliability.
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://eth-mainnet.public.blastapi.io")), FORK_BLOCK);
        vm.label(USDC, "USDC");
    }

    /// @notice Fund `to` with `amount` of `token` using Foundry `deal` (adjusts totalSupply for USDC/USDT).
    function _fund(address token, address to, uint256 amount) internal {
        deal(token, to, amount, true);
    }
}
