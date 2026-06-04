// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {HwmFeeMath} from "../../contracts/libraries/HwmFeeMath.sol";

/// @notice Deterministic unit tests for the per-user HWM fee math (no fork). Internal library
///         functions are inlined into this test contract.
contract HwmFeeMathTest is Test {
    uint256 constant WAD = 1e18;

    // ---------- deposit / withdrawal fee split ----------

    function test_splitFee_roundsUp() public pure {
        // 333 * 30bps = 0.999 -> rounds UP to 1 (protocol-favoring)
        (uint256 fee, uint256 net) = HwmFeeMath.splitFeeUp(333, 30);
        assertEq(fee, 1, "fee rounds up");
        assertEq(net, 332, "net = amount - fee");
    }

    function test_splitFee_zeroRate() public pure {
        (uint256 fee, uint256 net) = HwmFeeMath.splitFeeUp(1000, 0);
        assertEq(fee, 0);
        assertEq(net, 1000);
    }

    function test_splitFee_exact() public pure {
        (uint256 fee, uint256 net) = HwmFeeMath.splitFeeUp(10_000, 100); // 1%
        assertEq(fee, 100);
        assertEq(net, 9900);
    }

    // ---------- performance fee: HWM gate ----------

    function test_perf_zeroBelowHwm() public pure {
        // curRatio < hwm -> no fee (position under water)
        uint256 fee = HwmFeeMath.perfFeeAssets(100 * WAD, 11 * WAD / 10, 105 * WAD / 100, WAD, 2000);
        assertEq(fee, 0, "no fee below HWM");
    }

    function test_perf_zeroAtHwm() public pure {
        uint256 fee = HwmFeeMath.perfFeeAssets(100 * WAD, WAD, WAD, WAD, 2000);
        assertEq(fee, 0, "no fee exactly at HWM");
    }

    function test_perf_aboveHwm() public pure {
        // 100 shares, hwm 1.0, cur 1.1, 20% -> gain 10, fee 2 (1e18-scaled)
        uint256 fee = HwmFeeMath.perfFeeAssets(100 * WAD, WAD, 11 * WAD / 10, WAD, 2000);
        assertEq(fee, 2 * WAD, "20% of 10 gain");
    }

    function test_perf_zeroRateOrShares() public pure {
        assertEq(HwmFeeMath.perfFeeAssets(100 * WAD, WAD, 2 * WAD, WAD, 0), 0, "zero rate");
        assertEq(HwmFeeMath.perfFeeAssets(0, WAD, 2 * WAD, WAD, 2000), 0, "zero shares");
    }

    /// @notice The headline property: fees are PER-USER, not socialized. Same current price,
    ///         different personal HWMs -> different fees; an under-water user pays nothing.
    function test_perf_notSocialized() public pure {
        uint256 cur = 11 * WAD / 10; // 1.10
        uint256 perfBps = 2000;
        uint256 shares = 100 * WAD;

        uint256 feeA = HwmFeeMath.perfFeeAssets(shares, WAD, cur, WAD, perfBps); // entered at 1.00
        uint256 feeB = HwmFeeMath.perfFeeAssets(shares, 105 * WAD / 100, cur, WAD, perfBps); // entered at 1.05
        uint256 feeC = HwmFeeMath.perfFeeAssets(shares, 12 * WAD / 10, cur, WAD, perfBps); // entered at 1.20 (above)

        assertEq(feeA, 2 * WAD, "A: 20% of 10");
        assertEq(feeB, 1 * WAD, "B: 20% of 5");
        assertEq(feeC, 0, "C: above HWM pays nothing");
        assertGt(feeA, feeB, "different marks -> different fees");
    }

    // ---------- shares conversion (skim) ----------

    function test_assetsToSharesUp_roundsUp() public pure {
        // assets=10, curRatio=3, shareUnit=1 -> 10/3 = 3.33 -> 4 (round up so skim fully covers)
        uint256 s = HwmFeeMath.assetsToSharesUp(10, 3, 1);
        assertEq(s, 4);
    }

    function test_assetsToSharesUp_zero() public pure {
        assertEq(HwmFeeMath.assetsToSharesUp(0, 3, 1), 0);
    }

    // ---------- HWM ratchet ----------

    function test_maxHwm_ratchetsUpOnly() public pure {
        assertEq(HwmFeeMath.maxHwm(WAD, 2 * WAD), 2 * WAD, "up");
        assertEq(HwmFeeMath.maxHwm(2 * WAD, WAD), 2 * WAD, "never down");
        assertEq(HwmFeeMath.maxHwm(WAD, WAD), WAD, "flat");
    }

    // ---------- decimals: USDC-like (6-dec asset, 18-dec shares) ----------

    function test_perf_usdcLikeRatio() public pure {
        // SHARE_UNIT=1e18, ratio in 6-dec USDC base units per whole share.
        // hwm=1_000_000 (1.00 USDC), cur=1_022_800 (1.0228), shares=1_000e18, 20%
        uint256 fee = HwmFeeMath.perfFeeAssets(1_000 * WAD, 1_000_000, 1_022_800, WAD, 2000);
        // gain = 22_800 * 1000 = 22_800_000 base = 22.8 USDC ; 20% = 4.56 USDC = 4_560_000 base
        assertEq(fee, 4_560_000, "USDC-decimals perf fee");
    }

    // ---------- fuzz invariants ----------

    function testFuzz_perf_neverBelowHwm(uint256 shares, uint256 hwm, uint256 cur, uint16 perfBps) public pure {
        shares = bound(shares, 0, 1e30);
        hwm = bound(hwm, 1, 1e30);
        cur = bound(cur, 0, hwm); // cur <= hwm
        perfBps = uint16(bound(perfBps, 0, 3000));
        assertEq(HwmFeeMath.perfFeeAssets(shares, hwm, cur, WAD, perfBps), 0, "no fee at/below HWM");
    }

    function testFuzz_perf_feeNeverExceedsGain(uint256 shares, uint256 hwm, uint256 gainPerShare, uint16 perfBps)
        public
        pure
    {
        shares = bound(shares, 0, 1e24);
        hwm = bound(hwm, WAD / 100, 1e24);
        gainPerShare = bound(gainPerShare, 0, 1e24);
        perfBps = uint16(bound(perfBps, 0, 3000));
        uint256 cur = hwm + gainPerShare;
        uint256 fee = HwmFeeMath.perfFeeAssets(shares, hwm, cur, WAD, perfBps);
        uint256 gain = (gainPerShare * shares) / WAD;
        assertLe(fee, gain, "fee <= gain");
    }
}
