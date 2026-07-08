// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaseFork} from "../BaseFork.t.sol";
import {UltraYieldV2FeeCollector} from "../../contracts/UltraYieldV2FeeCollector.sol";
import {CuratedFeeCollectorBase} from "../../contracts/CuratedFeeCollectorBase.sol";
import {FeeMath} from "../../contracts/libraries/FeeMath.sol";

// Real UltraYield *V2* protocol code, compiled & deployed onto the fork (NOT a mock).
import {UltraVault, UltraVaultInitParams} from "uyv2/vaults/UltraVault.sol";
import {UltraVaultOracle} from "uyv2/oracles/UltraVaultOracle.sol";
import {UltraVaultRateProvider} from "uyv2/oracles/UltraVaultRateProvider.sol";
import {Fees} from "uyv2/interfaces/Types.sol";
import {ORACLE_KEY} from "uyv2/utils/AddressKeys.sol";

/// @notice Fork tests for the V2 partner-fee collector against a REAL self-deployed UltraYield **V2**
///         vault (UltraVault + UltraVaultOracle + UltraVaultRateProvider, no mocks). The test contract
///         is the vault owner (hence operator/pauser/admin via the role grants in initialize), the
///         fundsHolder (backs async redemptions), and drives operator fulfilment.
///
///         Covered:
///           - deposit fee taken to the partner,
///           - ASYNC exit (request -> operator fulfillMultipleRedeems -> claim): partner withdrawal + AUM
///             fees charged at claim, net to the user,
///           - INSTANT exit (V2): synchronous redeem against exitpoint liquidity, partner fees charged,
///           - partner-driven variants for both routes,
///           - the partner layer stacking ON TOP of the vault's OWN native withdrawal fee,
///           - access control + instant slippage guard.
contract UltraYieldV2FeeCollectorForkTest is BaseFork {
    UltraVaultRateProvider internal rp;
    UltraVaultOracle internal oracle;
    UltraVault internal vault;
    UltraYieldV2FeeCollector internal collector;

    address internal partner;
    address internal alice;
    address internal vaultFees; // the vault's OWN feeRecipient (distinct from partner)
    address internal exitpoint; // instant-redeem liquidity wallet

    uint16 internal constant DEP = 100; // 1% partner deposit fee
    uint16 internal constant WD = 50; // 0.5% partner withdrawal fee
    uint256 internal constant AUM = 1e9; // partner AUM fee per block (1e-9 of AUM/block)
    uint256 internal constant ONE = 1e18; // oracle share price 1:1

    function setUp() public {
        _fork();
        partner = makeAddr("partner");
        alice = makeAddr("alice");
        vaultFees = makeAddr("vaultFees");
        exitpoint = makeAddr("exitpoint");

        // 1) Rate provider: V2 is non-upgradeable; ctor auto-adds USDC as the pegged base asset.
        rp = new UltraVaultRateProvider(address(this), USDC);

        // 2) Vault implementation.
        UltraVault vImpl = new UltraVault();

        // 3) Vault proxy. The oracle ctor reads the vault (asset()/decimals()), and the vault init stores
        //    the oracle -> circular. initialize() never CALLS the oracle, so we init with a harmless
        //    placeholder (the rate provider: a non-zero contract) and swap to the real oracle below.
        Fees memory fees; // all-zero: isolate the partner fees from the vault's own fees
        UltraVaultInitParams memory p = UltraVaultInitParams({
            owner: address(this),
            asset: USDC,
            name: "UltraYield V2 USDC",
            symbol: "uy2USDC",
            rateProvider: address(rp),
            feeRecipient: vaultFees,
            fees: fees,
            oracle: address(rp), // placeholder; replaced via timelock before unpausing
            fundsHolder: address(this),
            instantRedeemExitpoint: exitpoint,
            upgradeModule: makeAddr("upgradeModule")
        });
        vault = UltraVault(address(new ERC1967Proxy(address(vImpl), abi.encodeCall(UltraVault.initialize, (p)))));

        // 4) Real oracle now that the vault exists & is initialized; seed price 1:1.
        oracle = new UltraVaultOracle(address(this), address(vault), ONE);

        // 5) Swap placeholder -> real oracle through the 3-day ORACLE_KEY timelock.
        //    acceptAddressUpdate() re-pauses the vault (so operators can verify the new wiring), so it
        //    requires the vault to be unpaused first; we unpause around it and unpause again at the end.
        vault.proposeAddressUpdate(ORACLE_KEY, address(oracle));
        vm.warp(block.timestamp + 3 days + 1);
        vault.unpause();
        vault.acceptAddressUpdate(ORACLE_KEY, address(oracle)); // re-pauses
        vault.unpause();

        // fundsHolder (this) backs async redemptions: hold a buffer and approve the vault to pull.
        IERC20(USDC).approve(address(vault), type(uint256).max);
        _fund(USDC, address(this), 5_000_000e6);

        // exitpoint backs instant redemptions: hold liquidity and approve the vault to pull.
        _fund(USDC, exitpoint, 5_000_000e6);
        vm.prank(exitpoint);
        IERC20(USDC).approve(address(vault), type(uint256).max);

        collector = new UltraYieldV2FeeCollector(IERC4626(address(vault)), address(this), partner, DEP, WD, AUM);
        vm.label(address(vault), "UltraVaultV2");
        vm.label(address(collector), "UltraYieldV2FeeCollector");
    }

    // --------------------------------------------------------------------
    // helpers
    // --------------------------------------------------------------------

    function _pendingShares(address user) internal view returns (uint256 s) {
        (s,) = collector.getPending(user);
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        _fund(USDC, user, assets);
        vm.startPrank(user);
        IERC20(USDC).approve(address(collector), assets);
        shares = collector.deposit(assets, user);
        vm.stopPrank();
    }

    /// @dev Operator (this) fulfils the collector's single pending parcel for `user`.
    function _fulfill(address user) internal {
        address[] memory assets = new address[](1);
        uint256[] memory shs = new uint256[](1);
        address[] memory ctrls = new address[](1);
        assets[0] = USDC;
        shs[0] = _pendingShares(user);
        ctrls[0] = address(collector);
        vault.fulfillMultipleRedeems(assets, shs, ctrls);
    }

    // --------------------------------------------------------------------
    // deposit
    // --------------------------------------------------------------------

    function test_Deposit_chargesDepositFee() public {
        _deposit(alice, 100_000e6);
        assertEq(IERC20(USDC).balanceOf(partner), 1_000e6, "deposit fee 1% -> partner");
        (uint256 ps,) = collector.getPosition(alice);
        assertGt(ps, 0, "position recorded");
        // 99k assets actually deposited at 1:1 -> ~99k shares
        assertApproxEqAbs(collector.getPositionValue(alice), 99_000e6, 2, "position value = net deposit");
    }

    // --------------------------------------------------------------------
    // async exit
    // --------------------------------------------------------------------

    function test_AsyncExit_feesAtClaim() public {
        _deposit(alice, 100_000e6);
        uint256 partnerAfterDep = IERC20(USDC).balanceOf(partner);

        vm.roll(block.number + 1_000_000); // under management for 1e6 blocks

        uint256 gross = collector.getPositionValue(alice);
        uint256 expWd = FeeMath.bpsFee(gross, WD);
        uint256 expAum = FeeMath.aumFee(gross, AUM, 1_000_000);

        vm.prank(alice);
        collector.requestRedeemAll();
        _fulfill(alice);

        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 net = collector.claim();

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, net, "net to user");
        uint256 feesToPartner = IERC20(USDC).balanceOf(partner) - partnerAfterDep;
        assertApproxEqAbs(feesToPartner, expWd + expAum, 2, "withdrawal + AUM charged at claim -> partner");
        assertApproxEqAbs(net, gross - expWd - expAum, 2, "user net after partner fees");
        assertGt(expAum, 0, "AUM accrued over blocks");
        console2.log("async partner fees (wd+aum) USDC:", feesToPartner);
        console2.log("async net to user USDC:", net);
    }

    function test_Async_partnerRequestAndClaimFor() public {
        _deposit(alice, 100_000e6);
        uint256 partnerAfterDep = IERC20(USDC).balanceOf(partner);
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);

        vm.roll(block.number + 400_000);
        uint256 gross = collector.getPositionValue(alice);

        // Partner drives the whole async exit on behalf of alice.
        vm.prank(partner);
        collector.requestRedeemAllFor(alice);
        _fulfill(alice);
        vm.prank(partner);
        uint256 net = collector.claimFor(alice);

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, net, "net assets to the USER");
        uint256 feesToPartner = IERC20(USDC).balanceOf(partner) - partnerAfterDep;
        assertApproxEqAbs(
            feesToPartner, FeeMath.bpsFee(gross, WD) + FeeMath.aumFee(gross, AUM, 400_000), 2, "fees to partner"
        );
        (uint256 ps,) = collector.getPosition(alice);
        assertEq(ps, 0, "position consumed");
    }

    // --------------------------------------------------------------------
    // instant exit (V2)
    // --------------------------------------------------------------------

    function test_InstantExit_chargesPartnerFees() public {
        _deposit(alice, 100_000e6);
        uint256 partnerAfterDep = IERC20(USDC).balanceOf(partner);

        vm.roll(block.number + 250_000);
        uint256 gross = collector.getPositionValue(alice);
        uint256 expWd = FeeMath.bpsFee(gross, WD);
        uint256 expAum = FeeMath.aumFee(gross, AUM, 250_000);

        assertGe(collector.getInstantLiquidity(), gross, "exitpoint has enough liquidity");

        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 net = collector.instantRedeemAll(0);

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, net, "net to user in same tx (synchronous)");
        uint256 feesToPartner = IERC20(USDC).balanceOf(partner) - partnerAfterDep;
        assertApproxEqAbs(feesToPartner, expWd + expAum, 2, "withdrawal + AUM charged -> partner");
        assertApproxEqAbs(net, gross - expWd - expAum, 2, "user net after partner fees");
        (uint256 ps,) = collector.getPosition(alice);
        assertEq(ps, 0, "position fully redeemed");
        console2.log("instant partner fees (wd+aum) USDC:", feesToPartner);
        console2.log("instant net to user USDC:", net);
    }

    function test_InstantExit_partnerDriven() public {
        _deposit(alice, 100_000e6);
        uint256 partnerAfterDep = IERC20(USDC).balanceOf(partner);
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);

        vm.roll(block.number + 100_000);
        uint256 gross = collector.getPositionValue(alice);
        uint256 shares = _allShares(alice); // capture before pranking (external call would consume the prank)

        vm.prank(partner);
        uint256 net = collector.instantRedeemFor(alice, shares, 0);

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, net, "net assets to the USER");
        uint256 feesToPartner = IERC20(USDC).balanceOf(partner) - partnerAfterDep;
        assertApproxEqAbs(
            feesToPartner, FeeMath.bpsFee(gross, WD) + FeeMath.aumFee(gross, AUM, 100_000), 2, "fees to partner"
        );
    }

    function _allShares(address user) internal view returns (uint256 s) {
        (s,) = collector.getPosition(user);
    }

    function test_InstantExit_slippageGuard() public {
        _deposit(alice, 100_000e6);
        uint256 gross = collector.getPositionValue(alice);
        // Demand more net than is mathematically possible after fees -> revert.
        vm.prank(alice);
        vm.expectRevert();
        collector.instantRedeemAll(gross + 1);
    }

    // --------------------------------------------------------------------
    // stacking: partner fee sits ON TOP of the vault's OWN native withdrawal fee
    // --------------------------------------------------------------------

    function test_AsyncExit_stacksOnTopOfVaultWithdrawalFee() public {
        // Turn ON the vault's own withdrawal fee (1%, the V2 max), recipient = vaultFees.
        Fees memory f;
        f.withdrawalFee = 1e16; // 1%
        vault.setFees(f);

        _deposit(alice, 100_000e6);
        uint256 partnerAfterDep = IERC20(USDC).balanceOf(partner);
        uint256 vaultFeesBefore = IERC20(USDC).balanceOf(vaultFees);

        uint256 grossAtVault = collector.getPositionValue(alice); // ~99k

        vm.prank(alice);
        collector.requestRedeemAll();
        _fulfill(alice); // vault deducts its 1% here, paid to vaultFees

        uint256 expVaultWd = grossAtVault / 100; // 1%
        // The collector only ever sees the post-vault-fee amount.
        uint256 grossToCollector = grossAtVault - expVaultWd;
        uint256 expPartnerWd = FeeMath.bpsFee(grossToCollector, WD);

        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 net = collector.claim();

        // vault's own fee landed at vaultFees, partner's fee at partner, both on the same exit.
        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, net, "net to user");
        assertApproxEqAbs(IERC20(USDC).balanceOf(vaultFees) - vaultFeesBefore, expVaultWd, 2, "vault native wd fee");
        assertApproxEqAbs(
            IERC20(USDC).balanceOf(partner) - partnerAfterDep, expPartnerWd, 2, "partner wd fee on net-of-vault gross"
        );
        assertApproxEqAbs(net, grossToCollector - expPartnerWd, 2, "user net after BOTH fee layers");
        console2.log("vault native wd fee USDC:", IERC20(USDC).balanceOf(vaultFees) - vaultFeesBefore);
        console2.log("partner wd fee USDC:", IERC20(USDC).balanceOf(partner) - partnerAfterDep);
    }

    // --------------------------------------------------------------------
    // access control
    // --------------------------------------------------------------------

    function test_requestFor_onlyPartner() public {
        _deposit(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(CuratedFeeCollectorBase.CuratedFeeCollector__NotPartner.selector);
        collector.requestRedeemAllFor(alice);
    }

    function test_instantFor_onlyPartner() public {
        _deposit(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(CuratedFeeCollectorBase.CuratedFeeCollector__NotPartner.selector);
        collector.instantRedeemFor(alice, 1, 0);
    }
}
