// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaseFork} from "../BaseFork.t.sol";
import {UltraYieldFeeCollector} from "../../contracts/UltraYieldFeeCollector.sol";
import {HwmFeeMath} from "../../contracts/libraries/HwmFeeMath.sol";

// Real UltraYield protocol code, compiled & deployed onto the fork (NOT a mock).
import {UltraVault, UltraVaultInitParams} from "src/vaults/UltraVault.sol";
import {UltraVaultOracle} from "src/oracles/UltraVaultOracle.sol";
import {UltraVaultRateProvider} from "src/oracles/UltraVaultRateProvider.sol";
import {Fees} from "src/interfaces/IUltraVault.sol";

/// @notice Fork tests for the asynchronous collector against a REAL UltraYield vault deployed onto the
///         mainnet fork. The test is the underlying vault's owner/operator/oracle-owner/fundsHolder, so it
///         can drive the NAV oracle UP and DOWN (exercising the HWM gate across a real drawdown) and
///         fulfill async redeems — all via real contract calls, no mocks.
contract UltraYieldFeeCollectorForkTest is BaseFork {
    UltraVaultOracle internal oracle;
    UltraVault internal vault;
    UltraYieldFeeCollector internal collector;

    address internal feeRec;
    address internal alice;
    address internal bob;

    uint16 internal constant DEP_FEE = 100; // 1%
    uint16 internal constant WD_FEE = 50; // 0.5%
    uint16 internal constant PERF_FEE = 2000; // 20%

    uint256 internal constant ONE = 1e18; // oracle price scale (1e18 == 1:1 share:USDC)

    function setUp() public {
        _fork();

        feeRec = makeAddr("feeRec");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // --- deploy real UltraYield (this == owner/operator/oracle-owner/fundsHolder) ---
        oracle = new UltraVaultOracle(address(this));

        UltraVaultRateProvider rpImpl = new UltraVaultRateProvider();
        UltraVaultRateProvider rp = UltraVaultRateProvider(
            address(new ERC1967Proxy(address(rpImpl), abi.encodeCall(UltraVaultRateProvider.initialize, (address(this), USDC))))
        );

        UltraVault vImpl = new UltraVault();
        Fees memory fees; // all zero: the UNDERLYING charges no fees; only the collector does
        UltraVaultInitParams memory p = UltraVaultInitParams({
            owner: address(this),
            asset: USDC,
            name: "UltraYield USDC",
            symbol: "uyUSDC",
            rateProvider: address(rp),
            feeRecipient: address(this),
            fees: fees,
            oracle: address(oracle),
            fundsHolder: address(this)
        });
        vault = UltraVault(address(new ERC1967Proxy(address(vImpl), abi.encodeCall(UltraVault.initialize, (p)))));

        _setRatio(ONE); // 1:1 to start
        vault.unpause();

        // fundsHolder (this) approves the vault to pull assets back on redeem fulfillment.
        IERC20(USDC).approve(address(vault), type(uint256).max);
        // Buffer so the fundsHolder can pay out NAV gains we simulate via the oracle.
        _fund(USDC, address(this), 5_000_000e6);

        collector = new UltraYieldFeeCollector(IERC4626(address(vault)), address(this), feeRec, DEP_FEE, WD_FEE, PERF_FEE);

        vm.label(address(vault), "UltraVault");
        vm.label(address(collector), "UltraYieldFeeCollector");
        vm.label(address(oracle), "UltraVaultOracle");
    }

    // --- helpers ---

    function _setRatio(uint256 priceWad) internal {
        oracle.setPrice(address(vault), USDC, priceWad);
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        _fund(USDC, user, assets);
        vm.startPrank(user);
        IERC20(USDC).approve(address(collector), assets);
        shares = collector.deposit(assets, user);
        vm.stopPrank();
    }

    /// @dev Operator fulfills the collector's pending redeem parcel, then the user claims.
    function _fulfillAndClaim(address user) internal returns (uint256 net) {
        uint256 pending = collector.pendingShares(user);
        vault.fulfillRedeem(USDC, pending, address(collector)); // onlyRole(OPERATOR_ROLE) == this
        vm.prank(user);
        net = collector.claim(user);
    }

    // ----------------------------------------------------------------
    // Async lifecycle + performance fee above HWM (real NAV move via oracle)
    // ----------------------------------------------------------------

    function test_AsyncLifecycle_perfFeeAboveHwm() public {
        _deposit(alice, 100_000e6); // 1% dep fee -> 99k net -> ~99k shares @ 1:1
        (uint256 sh0,) = collector.positionOf(alice);
        assertGt(sh0, 0, "alice has shares");

        // NAV +20% via the real oracle.
        _setRatio(12 * ONE / 10);
        assertGt(collector.pendingPerfFee(alice), 0, "perf fee accrued above HWM");

        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        collector.requestRedeemAll();

        // Perf fee was crystallized at request -> shares skimmed into the fee pool.
        assertGt(collector.accruedFeeShares(), 0, "perf fee skimmed at request");

        uint256 net = _fulfillAndClaim(alice);
        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, net, "alice received net");
        assertGt(net, 100_000e6, "alice made a net profit after all fees");
        // Net is below the full +20% gross (perf + withdrawal fees were taken).
        assertLt(net, 120_000e6, "fees were deducted from the gross gain");
        (uint256 shAfter,) = collector.positionOf(alice);
        assertEq(shAfter, 0, "position fully redeemed");
        console2.log("alice net out (USDC):", net);
    }

    // ----------------------------------------------------------------
    // HWM gate: up -> crystallize -> drawdown -> recover-below -> exceed (REAL oracle up & down)
    // ----------------------------------------------------------------

    function test_HwmGate_drawdownAndRecovery() public {
        _deposit(alice, 100_000e6);
        (, uint256 hwm0) = collector.positionOf(alice);

        // Up +20%: fee accrues; crystallize (P2P poke) -> HWM ratchets to ~1.2.
        _setRatio(12 * ONE / 10);
        assertGt(collector.pendingPerfFee(alice), 0, "fee above initial HWM");
        collector.crystallize(alice); // fee-authority (owner == this)
        (, uint256 hwm1) = collector.positionOf(alice);
        assertGt(hwm1, hwm0, "HWM ratcheted up");
        assertApproxEqRel(hwm1, 12 * collector.pricePerShare() / 12, 1e15, "hwm == current ratio");
        assertEq(collector.pendingPerfFee(alice), 0, "no fee right after crystallize");

        // Drawdown to 1.0 (below the 1.2 mark): NO fee.
        _setRatio(ONE);
        assertEq(collector.pendingPerfFee(alice), 0, "no fee during drawdown below HWM");

        // Partial recovery to 1.1 (still below 1.2): still NO fee (gate holds).
        _setRatio(11 * ONE / 10);
        assertEq(collector.pendingPerfFee(alice), 0, "no fee on partial recovery below HWM");

        // Exceed the prior peak to 1.3: fee accrues ONLY on the excess above 1.2.
        _setRatio(13 * ONE / 10);
        uint256 fee = collector.pendingPerfFee(alice);
        assertGt(fee, 0, "fee resumes only above prior HWM");

        (uint256 sh, uint256 hwmNow) = collector.positionOf(alice);
        uint256 expected = HwmFeeMath.perfFeeAssets(sh, hwmNow, collector.pricePerShare(), collector.SHARE_UNIT(), PERF_FEE);
        assertEq(fee, expected, "fee charged only on gain above the ratcheted mark");
        console2.log("fee on 1.2->1.3 excess only (USDC):", fee);
    }

    // ----------------------------------------------------------------
    // Per-user, NOT socialized — across a real drawdown
    // ----------------------------------------------------------------

    function test_NotSocialized_acrossDrawdown() public {
        // Alice enters at 1.0.
        _deposit(alice, 100_000e6);
        (, uint256 aliceHwm) = collector.positionOf(alice);

        // NAV rises to 1.2; Bob enters at the higher ratio.
        _setRatio(12 * ONE / 10);
        _deposit(bob, 100_000e6);
        (, uint256 bobHwm) = collector.positionOf(bob);
        assertGt(bobHwm, aliceHwm, "bob's personal mark is higher");

        // Drawdown to 1.1, then up to 1.25.
        _setRatio(11 * ONE / 10);
        assertEq(collector.pendingPerfFee(bob), 0, "bob under water at 1.1 (entered at 1.2)");
        assertGt(collector.pendingPerfFee(alice), 0, "alice still above her 1.0 mark");

        _setRatio(125 * ONE / 100);
        uint256 feeA = collector.pendingPerfFee(alice);
        uint256 feeB = collector.pendingPerfFee(bob);
        assertGt(feeA, 0, "alice owes fee (1.0 -> 1.25)");
        assertGt(feeB, 0, "bob owes fee (1.2 -> 1.25)");
        assertGt(feeA, feeB, "lower personal mark => higher fee (NOT socialized)");

        // Bob's fee is computed only against HIS own mark, not a shared/global one.
        (uint256 bobSh, uint256 bobMark) = collector.positionOf(bob);
        assertEq(
            feeB,
            HwmFeeMath.perfFeeAssets(bobSh, bobMark, collector.pricePerShare(), collector.SHARE_UNIT(), PERF_FEE),
            "bob charged on his own gain only"
        );
        console2.log("alice fee:", feeA);
        console2.log("bob fee:", feeB);
    }

    // ----------------------------------------------------------------
    // Drawdown passthrough: under water => no perf fee, user bears the loss
    // ----------------------------------------------------------------

    function test_Drawdown_noPerfFee_lossPassthrough() public {
        _deposit(alice, 100_000e6);
        _setRatio(9 * ONE / 10); // -10%

        assertEq(collector.pendingPerfFee(alice), 0, "no perf fee under water");

        vm.prank(alice);
        collector.requestRedeemAll();
        assertEq(collector.accruedFeeShares(), 0, "no perf fee skimmed under water");

        uint256 net = _fulfillAndClaim(alice);
        // Only the withdrawal fee + the real loss reduce the payout; below principal.
        assertLt(net, 100_000e6, "loss passed through to user");
        assertGt(net, 80_000e6, "roughly -10% minus withdrawal fee");
        console2.log("alice net after drawdown (USDC):", net);
    }

    // ----------------------------------------------------------------
    // Cancel before fulfillment restores the position
    // ----------------------------------------------------------------

    function test_CancelRequest_restoresPosition() public {
        uint256 sh = _deposit(alice, 100_000e6);
        vm.prank(alice);
        collector.requestRedeem(sh / 2);
        assertEq(collector.pendingShares(alice), sh / 2, "pending recorded");

        vm.prank(alice);
        collector.cancelRequest();
        assertEq(collector.pendingShares(alice), 0, "pending cleared");
        (uint256 shAfter,) = collector.positionOf(alice);
        assertEq(shAfter, sh, "shares restored to position");
    }

    // ----------------------------------------------------------------
    // Async fee collection (two-step) and sync-collect guard
    // ----------------------------------------------------------------

    function test_AsyncFeeCollection() public {
        _deposit(alice, 100_000e6);
        _setRatio(12 * ONE / 10);
        collector.crystallize(alice);
        uint256 feeShares = collector.accruedFeeShares();
        assertGt(feeShares, 0, "fee shares accrued");

        // sync collect is disabled for the async collector
        vm.expectRevert(UltraYieldFeeCollector.UseAsyncFeeCollection.selector);
        collector.collectFees();

        uint256 frBefore = IERC20(USDC).balanceOf(feeRec);
        collector.requestCollectFees(); // owner/feeRecipient
        // operator fulfills the fee parcel
        vault.fulfillRedeem(USDC, feeShares, address(collector));
        uint256 collected = collector.claimFees();
        assertGt(collected, 0, "fees collected to recipient");
        assertEq(IERC20(USDC).balanceOf(feeRec) - frBefore, collected, "feeRecipient received USDC");
        console2.log("async fees collected (USDC):", collected);
    }

    // ----------------------------------------------------------------
    // Fee-free underlying: the new UltraYield vault is configured with zero protocol fees
    // ----------------------------------------------------------------

    function test_underlyingIsFeeFree() public view {
        Fees memory f = vault.getFees();
        assertEq(f.performanceFee, 0, "underlying performance fee == 0");
        assertEq(f.managementFee, 0, "underlying management fee == 0");
        assertEq(f.withdrawalFee, 0, "underlying withdrawal fee == 0");
    }

    /// @notice With a fee-free underlying AND zero collector fees, the user receives the FULL NAV gain —
    ///         proving no fee is taken anywhere (the collector is the sole, and here disabled, fee layer).
    function test_feeFreeUnderlying_zeroCollectorFees_fullGainPassthrough() public {
        collector.setFees(0, 0, 0); // collector owner == this

        _deposit(alice, 100_000e6); // no deposit fee => 100k net deployed
        _setRatio(125 * ONE / 100); // NAV +25% via the oracle

        vm.prank(alice);
        collector.requestRedeemAll();
        assertEq(collector.accruedFeeShares(), 0, "no perf fee with zero collector fees");

        uint256 net = _fulfillAndClaim(alice);
        // Full +25% reaches the user: nothing skimmed by the underlying or the (disabled) collector.
        assertApproxEqRel(net, 125_000e6, 1e15, "full gross gain passes through; no fee anywhere");
        console2.log("fee-free full-passthrough net (USDC):", net);
    }
}
