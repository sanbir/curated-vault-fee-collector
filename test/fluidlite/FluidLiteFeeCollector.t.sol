// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseFork} from "../BaseFork.t.sol";
import {FluidLiteFeeCollector} from "../../contracts/FluidLiteFeeCollector.sol";
import {CuratedFeeCollectorBase} from "../../contracts/CuratedFeeCollectorBase.sol";
import {FeeMath} from "../../contracts/libraries/FeeMath.sol";

/// @notice Live-fork tests for the synchronous partner-fee collector against the REAL Fluid Lite USD vault
///         (`fLiteUSD`). No mocks. Verifies the three partner fees (deposit %, withdrawal %, per-block AUM)
///         all go to the partner, that net assets go to the user, and that the partner can withdraw for users.
contract FluidLiteFeeCollectorForkTest is BaseFork {
    address internal constant FLITE_USD = 0x273DA948ACa9261043fbdb2a857BC255ECC29012;

    IERC4626 internal underlying;
    FluidLiteFeeCollector internal collector;

    address internal owner; // P2P governance
    address internal partner; // fee recipient + withdrawer
    address internal alice;

    uint16 internal constant DEP = 100; // 1%
    uint16 internal constant WD = 50; // 0.5%
    uint256 internal constant AUM = 1e9; // 1e-9 of AUM per block

    function setUp() public {
        _fork();
        underlying = IERC4626(FLITE_USD);
        vm.label(FLITE_USD, "fLiteUSD");
        owner = makeAddr("owner");
        partner = makeAddr("partner");
        alice = makeAddr("alice");
        collector = new FluidLiteFeeCollector(underlying, owner, partner, DEP, WD, AUM);
        assertEq(address(collector.asset()), USDC, "asset USDC");
    }

    function _sharesOf(address user) internal view returns (uint256 s) {
        (s,) = collector.positionOf(user);
    }

    /// @dev Actual assets the collector receives on redeem = previewRedeem (accounts for fLiteUSD's
    ///      own native 0.05% withdrawal fee). The collector charges its partner fees on THIS amount.
    function _gross(address user) internal view returns (uint256) {
        return underlying.previewRedeem(_sharesOf(user));
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        _fund(USDC, user, assets);
        vm.startPrank(user);
        IERC20(USDC).approve(address(collector), assets);
        shares = collector.deposit(assets, user);
        vm.stopPrank();
    }

    // ---- deposit fee ----

    function test_Deposit_chargesDepositFeeToPartner() public {
        uint256 amt = 100_000e6;
        uint256 shares = _deposit(alice, amt);

        assertEq(IERC20(USDC).balanceOf(partner), amt / 100, "deposit fee 1% -> partner");
        assertEq(IERC20(FLITE_USD).balanceOf(address(collector)), shares, "collector custodies shares");
        assertEq(IERC20(FLITE_USD).balanceOf(alice), 0, "user holds no underlying shares");
        (uint256 ps, uint256 lastBlock) = collector.positionOf(alice);
        assertEq(ps, shares, "position recorded");
        assertEq(lastBlock, block.number, "AUM start block = deposit block");
    }

    // ---- withdrawal fee + AUM at withdrawal ----

    function test_Withdraw_chargesWithdrawalAndAumToPartner() public {
        _deposit(alice, 100_000e6);
        uint256 partnerAfterDep = IERC20(USDC).balanceOf(partner);

        vm.roll(block.number + 1_000_000); // assets under management for 1e6 blocks

        uint256 gross = _gross(alice); // ~ redeemed assetsGross
        uint256 expWd = FeeMath.bpsFee(gross, WD);
        uint256 expAum = FeeMath.aumFee(gross, AUM, 1_000_000);

        vm.prank(alice);
        uint256 net = collector.withdrawAll();

        uint256 partnerFees = IERC20(USDC).balanceOf(partner) - partnerAfterDep;
        assertApproxEqAbs(partnerFees, expWd + expAum, 50, "partner got withdrawal + AUM fee");
        assertApproxEqAbs(net, gross - expWd - expAum, 50, "user got net");
        assertEq(IERC20(USDC).balanceOf(alice), net, "net delivered to user");
        assertGt(expAum, 0, "AUM accrued over blocks");
        (uint256 ps,) = collector.positionOf(alice);
        assertEq(ps, 0, "position closed");
        console2.log("withdrawal fee + AUM (USDC):", partnerFees);
        console2.log("AUM portion (USDC):", expAum);
    }

    function test_NoAum_sameBlock() public {
        _deposit(alice, 50_000e6);
        uint256 partnerAfterDep = IERC20(USDC).balanceOf(partner);
        uint256 gross = _gross(alice);

        vm.prank(alice); // no vm.roll => 0 blocks under management
        collector.withdrawAll();

        uint256 fees = IERC20(USDC).balanceOf(partner) - partnerAfterDep;
        assertApproxEqAbs(fees, FeeMath.bpsFee(gross, WD), 50, "only withdrawal fee, no AUM at same block");
    }

    // ---- partner-initiated withdrawal: assets to user, fees to partner ----

    function test_Partner_withdrawForUser() public {
        _deposit(alice, 100_000e6);
        uint256 partnerAfterDep = IERC20(USDC).balanceOf(partner);
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);

        vm.roll(block.number + 500_000);
        uint256 gross = _gross(alice);

        // Partner withdraws on behalf of alice; alice never calls anything.
        vm.prank(partner);
        uint256 net = collector.withdrawAllFor(alice);

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, net, "net assets went to the USER");
        uint256 partnerFees = IERC20(USDC).balanceOf(partner) - partnerAfterDep;
        assertApproxEqAbs(partnerFees, FeeMath.bpsFee(gross, WD) + FeeMath.aumFee(gross, AUM, 500_000), 50, "fees to partner");
        (uint256 ps,) = collector.positionOf(alice);
        assertEq(ps, 0, "alice position closed by partner");
    }

    function test_withdrawFor_onlyPartner() public {
        _deposit(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(CuratedFeeCollectorBase.NotPartner.selector);
        collector.withdrawAllFor(alice);
    }

    // ---- AUM scales with blocks held ----

    function test_Aum_scalesWithBlocks() public {
        _deposit(alice, 100_000e6);
        uint256 gross = _gross(alice);
        uint256 short_ = FeeMath.aumFee(gross, AUM, 200_000);
        uint256 long_ = FeeMath.aumFee(gross, AUM, 800_000);
        assertGt(long_, short_, "longer management => higher AUM fee");
        assertApproxEqAbs(long_, 4 * short_, 4, "4x blocks => ~4x AUM");
    }

    // ---- top-up blends the AUM start block ----

    function test_TopUp_blendsLastBlock() public {
        _deposit(alice, 100_000e6);
        (, uint256 lb0) = collector.positionOf(alice);
        vm.roll(block.number + 1_000_000);
        _deposit(alice, 100_000e6);
        (, uint256 lb1) = collector.positionOf(alice);
        assertGt(lb1, lb0, "blended start block moved forward after top-up");
        assertLt(lb1, block.number, "but is before the top-up block (older tranche pulls it back)");
    }

    // ---- partial withdrawal preserves the AUM start block for the remainder ----

    function test_PartialWithdraw_preservesLastBlock() public {
        uint256 shares = _deposit(alice, 100_000e6);
        (, uint256 lb0) = collector.positionOf(alice);
        vm.roll(block.number + 300_000);
        vm.prank(alice);
        collector.withdraw(shares / 2);
        (uint256 ps, uint256 lb1) = collector.positionOf(alice);
        assertEq(lb1, lb0, "remainder keeps original AUM start block");
        assertApproxEqAbs(ps, shares - shares / 2, 1, "remaining shares");
    }

    // ---- admin / safety ----

    function test_setFees_capEnforced() public {
        vm.prank(owner);
        vm.expectRevert(CuratedFeeCollectorBase.FeeTooHigh.selector);
        collector.setFees(100, 501, AUM); // withdrawal > 5% cap

        vm.prank(owner);
        vm.expectRevert(CuratedFeeCollectorBase.FeeTooHigh.selector);
        collector.setFees(100, 50, 1e12 + 1); // AUM > cap

        vm.prank(owner);
        collector.setFees(200, 100, 2e9);
        assertEq(collector.aumFeePerBlock(), 2e9);
    }

    function test_onlyOwner_setFees_and_setPartner() public {
        vm.prank(alice);
        vm.expectRevert();
        collector.setFees(0, 0, 0);
        vm.prank(alice);
        vm.expectRevert();
        collector.setPartner(alice);
    }

    function test_pause_blocksDeposit() public {
        vm.prank(owner);
        collector.pause();
        _fund(USDC, alice, 1_000e6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(collector), 1_000e6);
        vm.expectRevert();
        collector.deposit(1_000e6, alice);
        vm.stopPrank();
    }

    function test_custodyOnly_noTransfer() public {
        (bool ok,) = address(collector).staticcall(abi.encodeWithSignature("transfer(address,uint256)", alice, 1));
        assertFalse(ok, "collector exposes no ERC20 transfer (positions non-transferable)");
    }
}
