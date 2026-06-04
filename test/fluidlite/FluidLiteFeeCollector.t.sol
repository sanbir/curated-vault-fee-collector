// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseFork} from "../BaseFork.t.sol";
import {FluidLiteFeeCollector} from "../../contracts/FluidLiteFeeCollector.sol";
import {CuratedFeeCollectorBase} from "../../contracts/CuratedFeeCollectorBase.sol";
import {HwmFeeMath} from "../../contracts/libraries/HwmFeeMath.sol";

/// @notice Live-fork tests for the synchronous collector against the REAL Fluid Lite USD vault
///         (`fLiteUSD`, 0x273D…9012). No mocks: real USDC, real vault, real auto-accrued yield
///         realized by warping time. Proves deposit/withdrawal fees and a PER-USER (non-socialized)
///         high-water-mark performance fee.
contract FluidLiteFeeCollectorForkTest is BaseFork {
    address internal constant FLITE_USD = 0x273DA948ACa9261043fbdb2a857BC255ECC29012;

    IERC4626 internal underlying;
    FluidLiteFeeCollector internal collector;

    address internal owner;
    address internal feeRecipient;
    address internal alice;
    address internal bob;

    uint16 internal constant DEP_FEE = 100; // 1%
    uint16 internal constant WD_FEE = 50; // 0.5%
    uint16 internal constant PERF_FEE = 2000; // 20%

    function setUp() public {
        _fork();
        underlying = IERC4626(FLITE_USD);
        vm.label(FLITE_USD, "fLiteUSD");

        owner = makeAddr("owner");
        feeRecipient = makeAddr("feeRecipient");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        collector = new FluidLiteFeeCollector(underlying, owner, feeRecipient, DEP_FEE, WD_FEE, PERF_FEE);
        vm.label(address(collector), "FluidLiteFeeCollector");

        // Sanity: the live vault is USDC-denominated and open for deposits.
        assertEq(address(collector.asset()), USDC, "asset is USDC");
        assertEq(collector.SHARE_UNIT(), 1e18, "fLiteUSD shares are 18-dec");
    }

    // ---- helpers ----

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        _fund(USDC, user, assets);
        vm.startPrank(user);
        IERC20(USDC).approve(address(collector), assets);
        shares = collector.deposit(assets, user);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------
    // Deposit fee + custody
    // ----------------------------------------------------------------

    function test_Deposit_chargesDepositFeeAndCustodiesShares() public {
        uint256 amt = 100_000e6;
        uint256 frBefore = IERC20(USDC).balanceOf(feeRecipient);

        uint256 shares = _deposit(alice, amt);

        // deposit fee (1%) went to feeRecipient in USDC
        assertEq(IERC20(USDC).balanceOf(feeRecipient) - frBefore, amt / 100, "deposit fee 1% to recipient");
        // collector custodies the fLiteUSD shares (user does NOT hold them)
        assertEq(IERC20(FLITE_USD).balanceOf(address(collector)), shares, "collector holds shares");
        assertEq(IERC20(FLITE_USD).balanceOf(alice), 0, "user holds no underlying shares");
        // position recorded with HWM = entry ratio
        (uint256 pShares, uint256 hwm) = collector.positionOf(alice);
        assertEq(pShares, shares, "position shares");
        assertEq(hwm, collector.pricePerShare(), "hwm = entry ratio");
        assertGt(shares, 0, "minted shares");
        console2.log("alice shares:", shares);
        console2.log("entry ratio (USDC/share, 6-dec):", hwm);
    }

    // ----------------------------------------------------------------
    // Performance fee above HWM, with REAL accrual
    // ----------------------------------------------------------------

    function test_PerfFee_realAccrual_aboveHwm() public {
        uint256 amt = 100_000e6;
        _deposit(alice, amt);
        uint256 ratio0 = collector.pricePerShare();

        // Realize ~180d of fLiteUSD auto-accrual (fixed/reward rate) — real, no mock.
        vm.warp(block.timestamp + 180 days);
        uint256 ratio1 = collector.pricePerShare();
        assertGt(ratio1, ratio0, "fLiteUSD price accrued over time");

        uint256 pendingFee = collector.pendingPerfFee(alice);
        assertGt(pendingFee, 0, "perf fee accrued above HWM");
        console2.log("ratio0:", ratio0);
        console2.log("ratio1:", ratio1);
        console2.log("pending perf fee (USDC):", pendingFee);

        // Redeem everything; collector skims perf-fee shares + withdrawal fee.
        uint256 frUsdcBefore = IERC20(USDC).balanceOf(feeRecipient);
        vm.prank(alice);
        uint256 net = collector.withdrawAll(alice);

        assertGt(collector.accruedFeeShares(), 0, "perf-fee shares skimmed into pool");
        // withdrawal fee (0.5%) paid to recipient in USDC
        assertGt(IERC20(USDC).balanceOf(feeRecipient), frUsdcBefore, "withdrawal fee to recipient");
        // user received net assets, and more than principal-minus-fees (made a profit net of perf fee)
        assertEq(IERC20(USDC).balanceOf(alice), net, "user got net out");
        assertGt(net, 0, "net out > 0");
        // position fully closed
        (uint256 pShares,) = collector.positionOf(alice);
        assertEq(pShares, 0, "position closed");

        // feeRecipient collects the perf-fee shares -> USDC
        uint256 frBefore2 = IERC20(USDC).balanceOf(feeRecipient);
        vm.prank(feeRecipient);
        uint256 collected = collector.collectFees();
        assertGt(collected, 0, "collected perf fee in USDC");
        assertEq(IERC20(USDC).balanceOf(feeRecipient) - frBefore2, collected, "perf fee reached recipient");
        assertEq(collector.accruedFeeShares(), 0, "fee pool drained");
        console2.log("perf fee collected (USDC):", collected);
    }

    // ----------------------------------------------------------------
    // PER-USER, NOT socialized: staggered entry => different personal HWMs
    // ----------------------------------------------------------------

    function test_PerfFee_isPerUser_notSocialized() public {
        uint256 amt = 100_000e6;

        // Alice enters early (low ratio).
        _deposit(alice, amt);
        (, uint256 aliceHwm) = collector.positionOf(alice);

        // Price rises for 120 days.
        vm.warp(block.timestamp + 120 days);

        // Bob enters later, at a HIGHER ratio than Alice's mark.
        uint256 bobShares = _deposit(bob, amt);
        (, uint256 bobHwm) = collector.positionOf(bob);
        assertGt(bobHwm, aliceHwm, "bob's personal HWM is higher (entered later)");

        // More accrual.
        vm.warp(block.timestamp + 120 days);
        uint256 cur = collector.pricePerShare();

        uint256 feeAlice = collector.pendingPerfFee(alice);
        uint256 feeBob = collector.pendingPerfFee(bob);

        // Both above their own marks now => both owe a fee.
        assertGt(feeAlice, 0, "alice owes perf fee");
        assertGt(feeBob, 0, "bob owes perf fee");
        // Alice (lower mark, more shares) owes strictly more than Bob.
        assertGt(feeAlice, feeBob, "lower personal HWM => higher fee (not socialized)");

        // Decisive non-socialization check: Bob's fee equals the fee computed ONLY against Bob's own
        // mark (it does NOT include the pre-Bob appreciation Alice earned). If it were socialized to a
        // single global mark, this independent recomputation would not match.
        (uint256 bobPos,) = collector.positionOf(bob);
        uint256 bobExpected =
            HwmFeeMath.perfFeeAssets(bobPos, bobHwm, cur, collector.SHARE_UNIT(), PERF_FEE);
        assertEq(feeBob, bobExpected, "bob charged only on his own gain above his own mark");
        assertEq(bobPos, bobShares, "bob position intact");

        console2.log("alice fee (USDC):", feeAlice);
        console2.log("bob fee   (USDC):", feeBob);
    }

    // ----------------------------------------------------------------
    // No perf fee for immediate round-trip (cur ~= hwm)
    // ----------------------------------------------------------------

    function test_NoPerfFee_immediateRoundTrip() public {
        uint256 amt = 50_000e6;
        _deposit(alice, amt);
        assertEq(collector.pendingPerfFee(alice), 0, "no perf fee at entry ratio");

        uint256 frBefore = IERC20(USDC).balanceOf(feeRecipient);
        vm.prank(alice);
        collector.withdrawAll(alice);
        // Only the withdrawal fee should have been taken on exit; no perf-fee shares skimmed.
        assertEq(collector.accruedFeeShares(), 0, "no perf fee skimmed on flat round-trip");
        assertGt(IERC20(USDC).balanceOf(feeRecipient), frBefore, "withdrawal fee charged");
    }

    // ----------------------------------------------------------------
    // Top-up: crystallize-then-raise (no fee forgiveness)
    // ----------------------------------------------------------------

    function test_TopUp_crystallizesThenRaisesHwm() public {
        _deposit(alice, 100_000e6);
        (, uint256 hwm0) = collector.positionOf(alice);

        vm.warp(block.timestamp + 200 days);
        uint256 pendingBeforeTopUp = collector.pendingPerfFee(alice);
        assertGt(pendingBeforeTopUp, 0, "gain accrued before top-up");

        // Top-up deposit crystallizes the pending fee, then raises the mark to the current ratio.
        _deposit(alice, 50_000e6);

        (, uint256 hwm1) = collector.positionOf(alice);
        assertGt(hwm1, hwm0, "HWM raised to current ratio after top-up");
        assertGt(collector.accruedFeeShares(), 0, "pending fee was crystallized, not forgiven");
        assertApproxEqAbs(collector.pendingPerfFee(alice), 0, 1, "no residual perf fee right after top-up");
    }

    // ----------------------------------------------------------------
    // Partial redeem preserves HWM (price)
    // ----------------------------------------------------------------

    function test_PartialRedeem_preservesHwm() public {
        _deposit(alice, 100_000e6);
        vm.warp(block.timestamp + 150 days);

        (uint256 sharesBefore,) = collector.positionOf(alice);
        // Crystallize will raise the mark to current ratio on this interaction; capture after.
        vm.prank(alice);
        collector.redeem(sharesBefore / 2, alice);

        (uint256 sharesAfter, uint256 hwmAfter) = collector.positionOf(alice);
        assertApproxEqAbs(hwmAfter, collector.pricePerShare(), 2, "hwm == current ratio (preserved as a price)");
        assertLt(sharesAfter, sharesBefore, "shares reduced by partial redeem");
        assertGt(sharesAfter, 0, "position still open");
        // Immediately after, no new perf fee (we just crystallized at this ratio).
        assertApproxEqAbs(collector.pendingPerfFee(alice), 0, 1, "no perf fee right after crystallize");
    }

    // ----------------------------------------------------------------
    // Caps, access control, pause, custody-only
    // ----------------------------------------------------------------

    function test_setFees_capEnforcedOnNewValue() public {
        vm.prank(owner);
        vm.expectRevert(CuratedFeeCollectorBase.FeeTooHigh.selector);
        collector.setFees(100, 100, 3001); // perf > 30% cap

        vm.prank(owner);
        collector.setFees(200, 100, 2500); // within caps
        assertEq(collector.perfFeeBps(), 2500);
    }

    function test_onlyOwner_setFees() public {
        vm.prank(alice);
        vm.expectRevert();
        collector.setFees(0, 0, 0);
    }

    function test_pause_blocksDeposit() public {
        vm.prank(owner);
        collector.pause();
        _fund(USDC, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(collector), 1_000e6);
        vm.expectRevert(); // Pausable: paused
        collector.deposit(1_000e6, alice);
        vm.stopPrank();
    }

    function test_custodyOnly_noPositionTransferFunction() public view {
        // The collector is NOT an ERC-20: positions cannot be transferred (no transfer/approve fns).
        // Selector for ERC20.transfer(address,uint256) must not be implemented.
        (bool ok,) = address(collector).staticcall(abi.encodeWithSignature("transfer(address,uint256)", alice, 1));
        assertFalse(ok, "collector exposes no ERC20 transfer (positions are non-transferable)");
    }
}
