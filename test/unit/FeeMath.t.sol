// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FeeMath} from "../../contracts/libraries/FeeMath.sol";

/// @notice Deterministic unit tests for the partner-fee math (deposit/withdrawal % + per-block AUM).
contract FeeMathTest is Test {
    uint256 constant WAD = 1e18;

    // ---------- bps fee (deposit / withdrawal) ----------

    function test_bpsFee_roundsUp() public pure {
        assertEq(FeeMath.bpsFee(333, 30), 1, "0.999 -> 1 (rounds up)");
        assertEq(FeeMath.bpsFee(10_000, 100), 100, "exact 1%");
        assertEq(FeeMath.bpsFee(1000, 0), 0, "zero rate");
        assertEq(FeeMath.bpsFee(0, 100), 0, "zero amount");
    }

    // ---------- AUM fee (per block) ----------

    function test_aumFee_zeroCases() public pure {
        assertEq(FeeMath.aumFee(1e18, 0, 100), 0, "zero rate");
        assertEq(FeeMath.aumFee(1e18, 1e9, 0), 0, "zero blocks");
        assertEq(FeeMath.aumFee(0, 1e9, 100), 0, "zero amount");
    }

    function test_aumFee_value() public pure {
        // amount=100_000e6 USDC, rate=1e9 (1e-9 per block), blocks=1e6 -> 100_000e6 * 1e-3 = 100e6 (100 USDC)
        uint256 fee = FeeMath.aumFee(100_000e6, 1e9, 1_000_000);
        assertEq(fee, 100e6, "0.1% of AUM over 1e6 blocks");
    }

    function test_aumFee_scalesWithBlocks() public pure {
        uint256 a = FeeMath.aumFee(100_000e6, 1e9, 500_000);
        uint256 b = FeeMath.aumFee(100_000e6, 1e9, 1_000_000);
        assertApproxEqAbs(b, 2 * a, 1, "2x blocks => ~2x AUM fee");
        assertGt(b, a, "more blocks => more fee");
    }

    function testFuzz_aumFee_monotonicInBlocks(uint256 amount, uint256 rate, uint64 b1, uint64 b2) public pure {
        amount = bound(amount, 0, 1e30);
        rate = bound(rate, 0, 1e12);
        vm.assume(b1 <= b2);
        assertLe(FeeMath.aumFee(amount, rate, b1), FeeMath.aumFee(amount, rate, b2), "non-decreasing in blocks");
    }

    function testFuzz_bpsFee_neverExceedsAmount(uint256 amount, uint16 rateBps) public pure {
        amount = bound(amount, 0, 1e30);
        rateBps = uint16(bound(rateBps, 0, 10_000));
        assertLe(FeeMath.bpsFee(amount, rateBps), amount, "fee <= amount when rate <= 100%");
    }
}
