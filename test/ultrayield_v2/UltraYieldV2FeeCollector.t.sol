// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseFork} from "../BaseFork.t.sol";
import {UltraYieldV2FeeCollector} from "../../contracts/UltraYieldV2FeeCollector.sol";
import {CuratedFeeCollectorBase} from "../../contracts/CuratedFeeCollectorBase.sol";
import {FeeMath} from "../../contracts/libraries/FeeMath.sol";

interface ILiveUltraVaultV2 is IERC4626 {
    function addToAllowlist(address account) external;
    function removeFromAllowlist(address account) external;
    function isAllowed(address account) external view returns (bool);
    function isAllowlistEnabled() external view returns (bool);
    function paused() external view returns (bool);
    function fundsHolder() external view returns (address);
    function feeRecipient() external view returns (address);
    function instantRedeemExitpoint() external view returns (address);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
    function getLiquidity(address asset) external view returns (uint256);
    function previewInstantRedeem(address asset, uint256 shares) external view returns (uint256);
    function getPendingRedeem(address asset, address controller)
        external
        view
        returns (uint256 shares, uint256 requestTime);
    function getClaimableRedeem(address asset, address controller)
        external
        view
        returns (uint256 assets, uint256 shares);
    function fulfillMultipleRedeems(
        address[] calldata assets,
        uint256[] calldata shares,
        address[] calldata controllers
    ) external returns (uint256[] memory assetsFulfilled);
}

/// @notice Mainnet-fork integration tests against the deployed UltraYield V2 proxy and implementation.
/// No protocol contracts are redeployed and no external call is mocked. `deal` only supplies the real
/// USDC token balances needed to exercise the existing funds-holder and exitpoint pull paths.
contract UltraYieldV2FeeCollectorLiveForkTest is BaseFork {
    address internal constant LIVE_VAULT = 0x02f4301b684600129913B66aEf9BE2c230a3BcAd;
    address internal constant LIVE_IMPLEMENTATION = 0x7f88A6c05EB87cCf7f1058D6477Bd542B901Da1E;
    address internal constant VAULT_ADMIN = 0x8d371EDcda960C746d0414139d15afF63E6b0516;
    address internal constant REDEEM_OPERATOR = 0x2Af4561F4344dCf58f76ADB29Da40ab950Bec544;
    address internal constant LIVE_FUNDS_HOLDER = 0xCa064C3080Db16133d4Ec48E768F2685f149Ea78;
    address internal constant LIVE_EXITPOINT = 0xD26E2e76442432aEEaC8e8D43Fa6f2421014F79b;
    bytes32 internal constant ALLOWLIST_ROLE = 0x26a560d834a19637eccba4611bbc09fb32970bb627da0a70f14f83fdc9822cbc;
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // A pinned block after the V2 deployment, less than 1,000 blocks behind the live head at test authoring.
    uint256 internal constant LIVE_FORK_BLOCK = 25_485_000;

    uint16 internal constant DEP = 100; // 1% partner deposit fee
    uint16 internal constant WD = 50; // 0.5% partner withdrawal fee
    uint256 internal constant AUM = 1e9; // 1e-9 of redeemed assets per block

    ILiveUltraVaultV2 internal vault = ILiveUltraVaultV2(LIVE_VAULT);
    UltraYieldV2FeeCollector internal collector;
    UltraYieldV2FeeCollector internal unlistedCollector;

    address internal owner;
    address internal partner;
    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), LIVE_FORK_BLOCK);

        owner = makeAddr("owner");
        partner = makeAddr("partner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        unlistedCollector = _deployCollector();
        collector = _deployCollector();

        // This is the same one-time onboarding transaction required in production. It exercises the
        // deployed vault's real ALLOWLIST_ROLE and ComplianceLib storage, rather than patching storage.
        vm.startPrank(VAULT_ADMIN);
        vault.grantRole(ALLOWLIST_ROLE, VAULT_ADMIN);
        vault.addToAllowlist(address(collector));
        vault.addToAllowlist(alice);
        vault.addToAllowlist(bob);
        vm.stopPrank();

        // The live vault pulls async liquidity from its configured funds holder and instant liquidity
        // from its configured exitpoint. Supply balances and real ERC20 allowances from those addresses.
        _fund(USDC, LIVE_FUNDS_HOLDER, 20_000_000e6);
        vm.prank(LIVE_FUNDS_HOLDER);
        IERC20(USDC).approve(LIVE_VAULT, type(uint256).max);

        _fund(USDC, LIVE_EXITPOINT, 20_000_000e6);
        vm.prank(LIVE_EXITPOINT);
        IERC20(USDC).approve(LIVE_VAULT, type(uint256).max);

        vm.label(LIVE_VAULT, "LiveUltraYieldV2");
        vm.label(address(collector), "UltraYieldV2FeeCollector");
        vm.label(VAULT_ADMIN, "LiveVaultAdmin");
        vm.label(REDEEM_OPERATOR, "LiveRedeemOperator");
        vm.label(LIVE_FUNDS_HOLDER, "LiveFundsHolder");
        vm.label(LIVE_EXITPOINT, "LiveInstantExitpoint");
    }

    function _deployCollector() internal returns (UltraYieldV2FeeCollector) {
        return new UltraYieldV2FeeCollector(IERC4626(LIVE_VAULT), owner, partner, DEP, WD, AUM);
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        _fund(USDC, user, assets);
        vm.startPrank(user);
        IERC20(USDC).approve(address(collector), assets);
        shares = collector.deposit(assets, user);
        vm.stopPrank();
    }

    function _positionShares(address user) internal view returns (uint256 shares) {
        (shares,) = collector.getPosition(user);
    }

    function _pendingShares(address user) internal view returns (uint256 shares) {
        (shares,) = collector.getPending(user);
    }

    function _fulfill(uint256 shares) internal returns (uint256 assetsFulfilled) {
        address[] memory assets = new address[](1);
        uint256[] memory shareAmounts = new uint256[](1);
        address[] memory controllers = new address[](1);
        assets[0] = USDC;
        shareAmounts[0] = shares;
        controllers[0] = address(collector);

        vm.prank(REDEEM_OPERATOR);
        uint256[] memory fulfilled = vault.fulfillMultipleRedeems(assets, shareAmounts, controllers);
        return fulfilled[0];
    }

    function test_LiveDeploymentIdentityAndOperationalPreconditions() public view {
        address implementation = address(uint160(uint256(vm.load(LIVE_VAULT, IMPLEMENTATION_SLOT))));
        assertEq(implementation, LIVE_IMPLEMENTATION, "unexpected live implementation");
        assertEq(vault.asset(), USDC, "collector assumes the vault's base asset");
        assertEq(vault.fundsHolder(), LIVE_FUNDS_HOLDER, "unexpected funds holder");
        assertEq(vault.instantRedeemExitpoint(), LIVE_EXITPOINT, "unexpected exitpoint");
        assertTrue(vault.isAllowlistEnabled(), "live allowlist must be enabled");
        assertFalse(vault.paused(), "live vault is paused");
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, VAULT_ADMIN), "unexpected live vault admin");
        assertTrue(vault.hasRole(ALLOWLIST_ROLE, VAULT_ADMIN), "vault admin failed to assume allowlist role");
        assertTrue(vault.isAllowed(address(collector)), "collector was not onboarded");
        assertFalse(vault.isAllowed(address(unlistedCollector)), "control collector unexpectedly allowlisted");
        assertEq(IERC20(LIVE_VAULT).allowance(address(collector), LIVE_VAULT), type(uint256).max);
    }

    function test_DepositRevertsUntilCollectorIsAllowlistedByUltraYield() public {
        uint256 assets = 1000e6;
        _fund(USDC, alice, assets);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(unlistedCollector), assets);
        vm.expectRevert(abi.encodeWithSignature("NotAllowlisted(address)", address(unlistedCollector)));
        unlistedCollector.deposit(assets, alice);
        vm.stopPrank();
    }

    function test_DepositRejectsUnallowedFunder() public {
        uint256 assets = 1000e6;
        _fund(USDC, carol, assets);
        uint256 partnerBefore = IERC20(USDC).balanceOf(partner);

        vm.startPrank(carol);
        IERC20(USDC).approve(address(collector), assets);
        vm.expectRevert(
            abi.encodeWithSelector(UltraYieldV2FeeCollector.UltraYieldV2FeeCollector__NotAllowed.selector, carol)
        );
        collector.deposit(assets, alice);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(carol), assets, "rejected funder keeps assets");
        assertEq(IERC20(USDC).balanceOf(partner), partnerBefore, "rejected deposit charges no fee");
        assertEq(_positionShares(alice), 0, "rejected deposit creates no position");
    }

    function test_DepositRejectsUnallowedBeneficiary() public {
        uint256 assets = 1000e6;
        _fund(USDC, alice, assets);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(collector), assets);
        vm.expectRevert(
            abi.encodeWithSelector(UltraYieldV2FeeCollector.UltraYieldV2FeeCollector__NotAllowed.selector, carol)
        );
        collector.deposit(assets, carol);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(alice), assets, "rejected beneficiary leaves funder whole");
        assertEq(_positionShares(carol), 0, "rejected beneficiary gets no position");
    }

    function test_DepositAllowsDistinctAllowedFunderAndBeneficiary() public {
        uint256 assets = 1000e6;
        _fund(USDC, alice, assets);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(collector), assets);
        uint256 shares = collector.deposit(assets, bob);
        vm.stopPrank();

        assertEq(_positionShares(alice), 0, "funder is not automatically beneficiary");
        assertEq(_positionShares(bob), shares, "allowed beneficiary receives internal position");
    }

    function test_LiveDepositChargesPartnerAndForwardsNetToRealFundsHolder() public {
        uint256 assets = 100_000e6;
        uint256 expectedDepositFee = FeeMath.bpsFee(assets, DEP);
        uint256 partnerBefore = IERC20(USDC).balanceOf(partner);
        uint256 fundsHolderBefore = IERC20(USDC).balanceOf(LIVE_FUNDS_HOLDER);

        uint256 shares = _deposit(alice, assets);

        assertEq(IERC20(USDC).balanceOf(partner) - partnerBefore, expectedDepositFee, "partner deposit fee");
        assertEq(
            IERC20(USDC).balanceOf(LIVE_FUNDS_HOLDER) - fundsHolderBefore,
            assets - expectedDepositFee,
            "live funds holder received net deposit"
        );
        assertEq(IERC20(LIVE_VAULT).balanceOf(address(collector)), shares, "collector custodies live shares");
        assertEq(_positionShares(alice), shares, "internal position matches live shares");
        assertEq(collector.getTotalShares(), shares, "total active shares");
        assertGt(shares, 0, "live vault minted no shares");
    }

    function test_LiveAsyncRequestFulfillClaimChargesWithdrawalAndAumFees() public {
        uint256 shares = _deposit(alice, 100_000e6);
        uint256 partnerAfterDeposit = IERC20(USDC).balanceOf(partner);
        (, uint256 aumStartBlock) = collector.getPosition(alice);
        vm.roll(block.number + 1_000_000);

        vm.prank(alice);
        uint256 requestId = collector.requestRedeemAll();
        assertEq(requestId, 0, "deployed V2 uses the singleton ERC-7540 request id");
        assertEq(_positionShares(alice), 0, "active position consumed at request");
        assertEq(_pendingShares(alice), shares, "collector pending parcel");
        (uint256 livePending,) = vault.getPendingRedeem(USDC, address(collector));
        assertEq(livePending, shares, "live vault pending parcel");
        assertEq(IERC20(LIVE_VAULT).balanceOf(LIVE_VAULT), shares, "shares escrowed in live vault");

        uint256 fulfilledAssets = _fulfill(shares);
        (uint256 claimableAssets, uint256 claimableShares) = vault.getClaimableRedeem(USDC, address(collector));
        assertEq(claimableShares, shares, "live claimable shares");
        assertEq(claimableAssets, fulfilledAssets, "live claimable assets");

        uint256 expectedWd = FeeMath.bpsFee(claimableAssets, WD);
        uint256 expectedAum = FeeMath.aumFee(claimableAssets, AUM, block.number - aumStartBlock);
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);

        vm.prank(alice);
        uint256 net = collector.claim();

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, net, "claim net to user");
        assertEq(
            IERC20(USDC).balanceOf(partner) - partnerAfterDeposit,
            expectedWd + expectedAum,
            "partner withdrawal plus AUM fees"
        );
        assertEq(net, claimableAssets - expectedWd - expectedAum, "net fee equation");
        assertEq(_pendingShares(alice), 0, "collector pending cleared");
        assertEq(collector.getTotalPending(), 0, "global pending cleared");
        assertEq(IERC20(LIVE_VAULT).balanceOf(address(collector)), 0, "all live shares exited");
    }

    function test_RemovalAfterDepositDoesNotBlockAsyncExit() public {
        uint256 shares = _deposit(alice, 10_000e6);

        vm.prank(VAULT_ADMIN);
        vault.removeFromAllowlist(alice);
        assertFalse(vault.isAllowed(alice), "user was not removed");

        vm.prank(alice);
        collector.requestRedeemAll();
        _fulfill(shares);

        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 net = collector.claim();

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, net, "removed user receives async exit");
        assertEq(_pendingShares(alice), 0, "removed user's pending position cleared");
    }

    function test_LiveInstantRedeemStacksNativePremiumAndPartnerFees() public {
        uint256 shares = _deposit(alice, 100_000e6);
        uint256 partnerAfterDeposit = IERC20(USDC).balanceOf(partner);
        address nativeFeeRecipient = vault.feeRecipient();
        uint256 nativeFeeRecipientBefore = IERC20(USDC).balanceOf(nativeFeeRecipient);
        (, uint256 aumStartBlock) = collector.getPosition(alice);
        vm.roll(block.number + 250_000);

        uint256 fromVault = vault.previewInstantRedeem(USDC, shares);
        uint256 grossAtOracle = vault.convertToAssets(shares);
        uint256 nativePremium = grossAtOracle - fromVault;
        uint256 expectedWd = FeeMath.bpsFee(fromVault, WD);
        uint256 expectedAum = FeeMath.aumFee(fromVault, AUM, block.number - aumStartBlock);
        uint256 expectedNet = fromVault - expectedWd - expectedAum;
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);

        vm.prank(alice);
        uint256 net = collector.instantRedeemAll(expectedNet);

        assertEq(net, expectedNet, "collector net matches both fee layers");
        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, expectedNet, "instant net to user");
        assertEq(
            IERC20(USDC).balanceOf(partner) - partnerAfterDeposit,
            expectedWd + expectedAum,
            "partner instant withdrawal plus AUM fees"
        );
        assertEq(
            IERC20(USDC).balanceOf(nativeFeeRecipient) - nativeFeeRecipientBefore,
            nativePremium,
            "UltraYield native instant premium"
        );
        assertEq(_positionShares(alice), 0, "position consumed");
        assertEq(IERC20(LIVE_VAULT).balanceOf(address(collector)), 0, "live shares burned");
    }

    function test_RemovalAfterDepositDoesNotBlockInstantExit() public {
        _deposit(bob, 10_000e6);

        vm.prank(VAULT_ADMIN);
        vault.removeFromAllowlist(bob);
        assertFalse(vault.isAllowed(bob), "user was not removed");

        uint256 bobBefore = IERC20(USDC).balanceOf(bob);
        vm.prank(bob);
        uint256 net = collector.instantRedeemAll(0);

        assertEq(IERC20(USDC).balanceOf(bob) - bobBefore, net, "removed user receives instant exit");
        assertEq(_positionShares(bob), 0, "removed user's position cleared");
    }

    function test_LivePartnerCanDriveAsyncExitButAssetsStillGoToUser() public {
        uint256 shares = _deposit(alice, 20_000e6);
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        uint256 partnerAfterDeposit = IERC20(USDC).balanceOf(partner);
        vm.roll(block.number + 40_000);

        vm.prank(partner);
        collector.requestRedeemAllFor(alice);
        uint256 fulfilledAssets = _fulfill(shares);

        vm.prank(partner);
        uint256 net = collector.claimFor(alice);

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, net, "partner cannot redirect principal");
        assertGt(IERC20(USDC).balanceOf(partner) - partnerAfterDeposit, 0, "partner charged no exit fees");
        assertLt(net, fulfilledAssets, "partner exit fees were not deducted");
    }

    function test_LiveAggregatedUsersCanClaimFromOneVaultController() public {
        uint256 aliceShares = _deposit(alice, 30_000e6);
        uint256 bobShares = _deposit(bob, 70_000e6);

        vm.prank(alice);
        collector.requestRedeemAll();
        vm.prank(bob);
        collector.requestRedeemAll();

        (uint256 livePending,) = vault.getPendingRedeem(USDC, address(collector));
        assertEq(livePending, aliceShares + bobShares, "live vault aggregates collector users");
        _fulfill(aliceShares + bobShares);

        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 aliceNet = collector.claim();
        uint256 bobBefore = IERC20(USDC).balanceOf(bob);
        vm.prank(bob);
        uint256 bobNet = collector.claim();

        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, aliceNet, "alice net");
        assertEq(IERC20(USDC).balanceOf(bob) - bobBefore, bobNet, "bob net");
        assertEq(_pendingShares(alice), 0, "alice pending cleared");
        assertEq(_pendingShares(bob), 0, "bob pending cleared");
        assertEq(collector.getTotalPending(), 0, "aggregate pending cleared");
        assertEq(IERC20(LIVE_VAULT).balanceOf(address(collector)), 0, "aggregate live shares exited");
    }

    function test_LivePartialFulfillmentOnlyClaimsAvailableShares() public {
        uint256 shares = _deposit(alice, 100_000e6);
        vm.prank(alice);
        collector.requestRedeemAll();

        uint256 firstParcel = shares / 3;
        _fulfill(firstParcel);
        vm.prank(alice);
        collector.claim();

        assertEq(_pendingShares(alice), shares - firstParcel, "unfulfilled collector shares remain pending");
        assertEq(collector.getTotalPending(), shares - firstParcel, "global pending tracks remainder");
        (uint256 livePending,) = vault.getPendingRedeem(USDC, address(collector));
        assertEq(livePending, shares - firstParcel, "live pending tracks remainder");

        _fulfill(shares - firstParcel);
        vm.prank(alice);
        collector.claim();
        assertEq(_pendingShares(alice), 0, "second claim clears pending");
        assertEq(collector.getTotalPending(), 0, "second claim clears global pending");
    }

    function test_LiveInstantSlippageGuardRevertsAtomically() public {
        uint256 shares = _deposit(alice, 10_000e6);
        uint256 possibleFromVault = vault.previewInstantRedeem(USDC, shares);
        uint256 impossibleNet = possibleFromVault + 1;
        uint256 collectorSharesBefore = IERC20(LIVE_VAULT).balanceOf(address(collector));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                UltraYieldV2FeeCollector.UltraYieldV2FeeCollector__SlippageExceeded.selector,
                possibleFromVault - FeeMath.bpsFee(possibleFromVault, WD),
                impossibleNet
            )
        );
        collector.instantRedeemAll(impossibleNet);

        assertEq(_positionShares(alice), shares, "position rolled back");
        assertEq(IERC20(LIVE_VAULT).balanceOf(address(collector)), collectorSharesBefore, "live burn rolled back");
    }

    function test_RequestAndInstantForRemainPartnerOnlyOnLiveVault() public {
        _deposit(alice, 1000e6);

        vm.prank(alice);
        vm.expectRevert(CuratedFeeCollectorBase.CuratedFeeCollector__NotPartner.selector);
        collector.requestRedeemAllFor(alice);

        vm.prank(alice);
        vm.expectRevert(CuratedFeeCollectorBase.CuratedFeeCollector__NotPartner.selector);
        collector.instantRedeemFor(alice, 1, 0);
    }
}
