// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseFork} from "../BaseFork.t.sol";
import {FluidLiteFeeCollector} from "../../contracts/FluidLiteFeeCollector.sol";

/// @notice Proves the design assumption that the NEW curated vaults are configured FEE-FREE at the
///         underlying, so the collector is the ONLY fee layer. Uses the live, real, synchronous,
///         fee-free Fluid `fUSDC` ERC-4626 vault as the fee-free underlying (no mocks). The example
///         project confirms fUSDC round-trips ~1:1 (no deposit/withdraw fee); these tests assert it
///         directly and then show that with collector fees on, the only deductions are the collector's.
contract FeeFreeUnderlyingTest is BaseFork {
    // Fluid fUSDC: real synchronous ERC-4626, USDC-denominated, NO deposit/withdrawal fee.
    address internal constant F_USDC = 0x9Fb7b4477576Fe5B32be4C1843aFB1e55F251B33;

    IERC4626 internal underlying;
    address internal owner;
    address internal feeRecipient;
    address internal alice;

    function setUp() public {
        _fork();
        underlying = IERC4626(F_USDC);
        vm.label(F_USDC, "fUSDC");
        owner = makeAddr("owner");
        feeRecipient = makeAddr("feeRecipient");
        alice = makeAddr("alice");
        assertEq(underlying.asset(), USDC, "fUSDC is USDC-denominated");
    }

    function _newCollector(uint16 dep, uint16 wd, uint16 perf) internal returns (FluidLiteFeeCollector c) {
        c = new FluidLiteFeeCollector(underlying, owner, feeRecipient, dep, wd, perf);
    }

    function _deposit(FluidLiteFeeCollector c, address user, uint256 assets) internal returns (uint256 shares) {
        _fund(USDC, user, assets);
        vm.startPrank(user);
        IERC20(USDC).approve(address(c), assets);
        shares = c.deposit(assets, user);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------
    // (a) Underlying takes NO deposit/withdrawal fee: zero-fee collector round-trips ~1:1
    // ----------------------------------------------------------------

    function test_FeeFreeUnderlying_zeroCollectorFees_immediateRoundTrip() public {
        FluidLiteFeeCollector c = _newCollector(0, 0, 0); // collector charges nothing
        uint256 amt = 200_000e6;

        _deposit(c, alice, amt);
        // No collector fee on deposit => feeRecipient untouched, full amount deployed.
        assertEq(IERC20(USDC).balanceOf(feeRecipient), 0, "no deposit fee taken");

        vm.prank(alice);
        uint256 net = c.withdrawAll(alice);

        // fUSDC has no deposit/withdrawal fee, so the round-trip returns ~the full principal (<=2 wei loss/share rounding).
        assertApproxEqAbs(net, amt, 5, "fee-free underlying: round-trip ~= principal");
        assertEq(IERC20(USDC).balanceOf(feeRecipient), 0, "no withdrawal fee taken either");
        console2.log("round-trip net vs principal (USDC):", net, amt);
    }

    // ----------------------------------------------------------------
    // (b) Underlying takes nothing on the YIELD either: grown redeem == NAV (convertToAssets)
    // ----------------------------------------------------------------

    function test_FeeFreeUnderlying_zeroCollectorFees_grownRedeemEqualsNav() public {
        FluidLiteFeeCollector c = _newCollector(0, 0, 0);
        _deposit(c, alice, 200_000e6);

        vm.warp(block.timestamp + 200 days); // real fUSDC lending yield accrues

        uint256 navBefore = c.positionValue(alice); // convertToAssets(shares) — the collector's gross view
        assertGt(navBefore, 200_000e6, "fUSDC accrued real yield");

        vm.prank(alice);
        uint256 net = c.withdrawAll(alice);

        // With zero collector fees AND a fee-free underlying, the user receives exactly the NAV the
        // collector accounted for — i.e., the underlying skimmed nothing on the grown amount.
        assertApproxEqAbs(net, navBefore, 5, "fee-free underlying: redeem proceeds == accounted NAV");
        assertEq(IERC20(USDC).balanceOf(feeRecipient), 0, "no fee leaked to anyone");
        console2.log("grown NAV (USDC):", navBefore);
        console2.log("user net    (USDC):", net);
    }

    // ----------------------------------------------------------------
    // (c) With collector fees ON, the ONLY deductions are the collector's (nothing to the underlying)
    // ----------------------------------------------------------------

    uint16 internal constant DEP = 100; // 1%
    uint16 internal constant WD = 50; // 0.5%
    uint16 internal constant PERF = 2000; // 20%
    uint256 internal constant A = 200_000e6;

    function test_FeeFreeUnderlying_collectorIsOnlyFeeLayer() public {
        FluidLiteFeeCollector c = _newCollector(DEP, WD, PERF);

        _deposit(c, alice, A);
        uint256 depFee = IERC20(USDC).balanceOf(feeRecipient); // started at 0
        assertApproxEqAbs(depFee, A / 100, 1, "deposit fee 1%");
        uint256 net = A - depFee; // principal deployed into the fee-free underlying

        vm.warp(block.timestamp + 200 days);

        uint256 grossNav = c.positionValue(alice); // pre-redeem gross value (collector's accounted NAV)
        uint256 gain = grossNav - net;
        assertGt(gain, 0, "real yield");
        uint256 expectedPerf = (gain * PERF) / 10_000; // ~20% of the FULL gain (underlying takes nothing)

        uint256 userNet;
        uint256 wdFee;
        {
            uint256 frBefore = IERC20(USDC).balanceOf(feeRecipient);
            vm.prank(alice);
            userNet = c.withdrawAll(alice);
            wdFee = IERC20(USDC).balanceOf(feeRecipient) - frBefore;
        }
        vm.prank(feeRecipient);
        uint256 perfCollected = c.collectFees();

        // If the underlying had taken any fee, redeem proceeds would fall short of grossNav and these
        // checks would fail. They pass => underlying is fee-free; the collector is the only fee layer.
        {
            uint256 grossAfterPerf = grossNav - expectedPerf;
            uint256 expectedUserNet = grossAfterPerf - (grossAfterPerf * WD) / 10_000;
            assertApproxEqRel(userNet, expectedUserNet, 1e15, "user net == NAV minus ONLY collector perf+wd");
            assertApproxEqRel(wdFee, (grossAfterPerf * WD) / 10_000, 1e15, "withdrawal fee == 0.5% post-perf");
        }
        assertApproxEqRel(perfCollected, expectedPerf, 1e15, "perf fee == 20% of the FULL gain");

        // Value conservation: in (principal + real yield) == out (user + ALL collector fees); no leak.
        assertApproxEqAbs(userNet + depFee + wdFee + perfCollected, A + gain, 10, "conservation: no leak to underlying");

        console2.log("gain (USDC):", gain);
        console2.log("perf collected (USDC):", perfCollected);
        console2.log("user net (USDC):", userNet);
    }
}
