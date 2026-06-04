// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaseFork} from "../BaseFork.t.sol";
import {UltraYieldFeeCollector} from "../../contracts/UltraYieldFeeCollector.sol";
import {CuratedFeeCollectorBase} from "../../contracts/CuratedFeeCollectorBase.sol";
import {FeeMath} from "../../contracts/libraries/FeeMath.sol";

// Real UltraYield protocol code, compiled & deployed onto the fork (NOT a mock).
import {UltraVault, UltraVaultInitParams} from "src/vaults/UltraVault.sol";
import {UltraVaultOracle} from "src/oracles/UltraVaultOracle.sol";
import {UltraVaultRateProvider} from "src/oracles/UltraVaultRateProvider.sol";
import {Fees} from "src/interfaces/IUltraVault.sol";

/// @notice Fork tests for the asynchronous partner-fee collector against a REAL self-deployed UltraYield
///         vault. The test is the vault's owner/operator/oracle-owner/fundsHolder. Verifies deposit fee,
///         the async request->fulfill->claim exit with withdrawal + per-block AUM fees charged at claim,
///         and partner-initiated request/claim on behalf of users.
contract UltraYieldFeeCollectorForkTest is BaseFork {
    UltraVaultOracle internal oracle;
    UltraVault internal vault;
    UltraYieldFeeCollector internal collector;

    address internal partner;
    address internal alice;

    uint16 internal constant DEP = 100; // 1%
    uint16 internal constant WD = 50; // 0.5%
    uint256 internal constant AUM = 1e9; // 1e-9 of AUM per block
    uint256 internal constant ONE = 1e18; // oracle 1:1

    function setUp() public {
        _fork();
        partner = makeAddr("partner");
        alice = makeAddr("alice");

        oracle = new UltraVaultOracle(address(this));
        UltraVaultRateProvider rpImpl = new UltraVaultRateProvider();
        UltraVaultRateProvider rp = UltraVaultRateProvider(
            address(new ERC1967Proxy(address(rpImpl), abi.encodeCall(UltraVaultRateProvider.initialize, (address(this), USDC))))
        );
        UltraVault vImpl = new UltraVault();
        Fees memory fees; // underlying native fees not relevant here; collector charges the partner fees
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
        oracle.setPrice(address(vault), USDC, ONE);
        vault.unpause();
        IERC20(USDC).approve(address(vault), type(uint256).max); // fundsHolder approves vault for redemptions
        _fund(USDC, address(this), 5_000_000e6); // buffer to pay redemptions

        collector = new UltraYieldFeeCollector(IERC4626(address(vault)), address(this), partner, DEP, WD, AUM);
        vm.label(address(vault), "UltraVault");
        vm.label(address(collector), "UltraYieldFeeCollector");
    }

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

    function test_AsyncDeposit_chargesDepositFee() public {
        _deposit(alice, 100_000e6);
        assertEq(IERC20(USDC).balanceOf(partner), 1_000e6, "deposit fee 1% -> partner");
        (uint256 ps,) = collector.getPosition(alice);
        assertGt(ps, 0, "position recorded");
    }

    function test_AsyncExit_feesAtClaim() public {
        _deposit(alice, 100_000e6);
        uint256 partnerAfterDep = IERC20(USDC).balanceOf(partner);

        vm.roll(block.number + 1_000_000); // under management for 1e6 blocks

        uint256 gross = collector.getPositionValue(alice);
        uint256 expWd = FeeMath.bpsFee(gross, WD);
        uint256 expAum = FeeMath.aumFee(gross, AUM, 1_000_000);

        vm.prank(alice);
        collector.requestRedeemAll();
        // operator (this) fulfills the collector's pending parcel
        vault.fulfillRedeem(USDC, _pendingShares(alice), address(collector));

        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 net = collector.claim();

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, net, "net to user");
        uint256 fees = IERC20(USDC).balanceOf(partner) - partnerAfterDep;
        assertApproxEqAbs(fees, expWd + expAum, 2, "withdrawal + AUM fee charged at claim -> partner");
        assertApproxEqAbs(net, gross - expWd - expAum, 2, "user net after fees");
        assertGt(expAum, 0, "AUM accrued over blocks");
        console2.log("async fees (wd+aum) USDC:", fees);
        console2.log("async net to user USDC:", net);
    }

    function test_Partner_requestAndClaimFor() public {
        _deposit(alice, 100_000e6);
        uint256 partnerAfterDep = IERC20(USDC).balanceOf(partner);
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);

        vm.roll(block.number + 400_000);
        uint256 gross = collector.getPositionValue(alice);

        // Partner drives the whole async exit on behalf of alice.
        vm.prank(partner);
        collector.requestRedeemAllFor(alice);
        vault.fulfillRedeem(USDC, _pendingShares(alice), address(collector));
        vm.prank(partner);
        uint256 net = collector.claimFor(alice);

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, net, "net assets to the USER");
        uint256 fees = IERC20(USDC).balanceOf(partner) - partnerAfterDep;
        assertApproxEqAbs(fees, FeeMath.bpsFee(gross, WD) + FeeMath.aumFee(gross, AUM, 400_000), 2, "fees to partner");
        (uint256 ps,) = collector.getPosition(alice);
        assertEq(ps, 0, "position consumed");
    }

    function test_requestFor_onlyPartner() public {
        _deposit(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(CuratedFeeCollectorBase.CuratedFeeCollector__NotPartner.selector);
        collector.requestRedeemAllFor(alice);
    }
}
