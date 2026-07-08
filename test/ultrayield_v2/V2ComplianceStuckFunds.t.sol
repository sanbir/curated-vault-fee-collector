// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BaseFork} from "../BaseFork.t.sol";

// Real UltraYield *V2* protocol code, compiled & deployed onto the fork (NOT a mock).
import {UltraVault, UltraVaultInitParams} from "uyv2/vaults/UltraVault.sol";
import {UltraVaultOracle} from "uyv2/oracles/UltraVaultOracle.sol";
import {UltraVaultRateProvider} from "uyv2/oracles/UltraVaultRateProvider.sol";
import {Fees, PendingRedeem, ClaimableRedeem} from "uyv2/interfaces/Types.sol";
import {ORACLE_KEY} from "uyv2/utils/AddressKeys.sol";
import {COMPLIANCE_ROLE} from "uyv2/utils/Roles.sol";
import {IComplianceErrors} from "uyv2/interfaces/ICompliance.sol";
import {IBaseVaultErrors} from "uyv2/interfaces/IBaseVault.sol";

/// @notice No-mock mainnet-fork PoC probing whether a blocklisted V2 *depositor* can have stuck funds.
///
///         The user deposits DIRECTLY into the REAL self-deployed UltraVault (UltraVault +
///         UltraVaultOracle + UltraVaultRateProvider). The test contract is the vault owner
///         (DEFAULT_ADMIN_ROLE => grants itself COMPLIANCE_ROLE; already holds OPERATOR_ROLE),
///         the fundsHolder (backs async redemptions), and drives operator fulfilment. A separate
///         `exitpoint` backs instant redeems.
///
///         Value can live in THREE places:
///           (a) WALLET shares          -> balanceOf(alice)
///           (b) PENDING redeem         -> shares escrowed in the vault awaiting operator fulfilment
///           (c) CLAIMABLE redeem       -> operator fulfilled; assets owed, redeemable
///
///         Each scenario asserts the EXACT guard behavior (vm.expectRevert with the named error,
///         or balance deltas) so the result is mechanical ground truth, not a manual trace.
contract V2ComplianceStuckFundsForkTest is BaseFork {
    UltraVaultRateProvider internal rp;
    UltraVaultOracle internal oracle;
    UltraVault internal vault;

    address internal alice;
    address internal cleanReceiver; // an unrestricted, otherwise-uninvolved address
    address internal vaultFees; // the vault's feeRecipient
    address internal exitpoint; // instant-redeem liquidity wallet

    uint256 internal constant ONE = 1e18; // oracle share price 1:1
    uint256 internal constant DEPOSIT = 100_000e6; // 100k USDC

    function setUp() public {
        _fork();
        alice = makeAddr("alice");
        cleanReceiver = makeAddr("cleanReceiver");
        vaultFees = makeAddr("vaultFees");
        exitpoint = makeAddr("exitpoint");

        // 1) Rate provider: V2 is non-upgradeable; ctor auto-adds USDC as the pegged base asset.
        rp = new UltraVaultRateProvider(address(this), USDC);

        // 2) Vault implementation.
        UltraVault vImpl = new UltraVault();

        // 3) Vault proxy. The oracle ctor reads the vault (asset()/decimals()), and the vault init stores
        //    the oracle -> circular. initialize() never CALLS the oracle, so we init with a harmless
        //    placeholder (the rate provider: a non-zero contract) and swap to the real oracle below.
        Fees memory fees; // all-zero fees: isolate compliance behavior from fee accounting
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
        vault.proposeAddressUpdate(ORACLE_KEY, address(oracle));
        vm.warp(block.timestamp + 3 days + 1);
        vault.unpause();
        vault.acceptAddressUpdate(ORACLE_KEY, address(oracle)); // re-pauses
        vault.unpause();

        // Grant COMPLIANCE_ROLE to the test contract (owner holds DEFAULT_ADMIN_ROLE).
        vault.grantRole(COMPLIANCE_ROLE, address(this));

        // fundsHolder (this) backs async redemptions: hold a buffer and approve the vault to pull.
        IERC20(USDC).approve(address(vault), type(uint256).max);
        _fund(USDC, address(this), 5_000_000e6);

        // exitpoint backs instant redemptions: hold liquidity and approve the vault to pull.
        _fund(USDC, exitpoint, 5_000_000e6);
        vm.prank(exitpoint);
        IERC20(USDC).approve(address(vault), type(uint256).max);

        vm.label(address(vault), "UltraVaultV2");
        vm.label(alice, "alice");
        vm.label(cleanReceiver, "cleanReceiver");
    }

    // --------------------------------------------------------------------
    // helpers
    // --------------------------------------------------------------------

    /// @dev Alice deposits DIRECTLY into the vault and receives wallet shares.
    /// @dev Also pre-approves the vault to pull her shares for requestRedeem (ERC-7540 pulls via
    ///      _spendAllowance(owner, vault, shares) before transferring shares to escrow). Granting the
    ///      allowance up front ensures requestRedeem reverts on the COMPLIANCE gate, not on allowance.
    function _aliceDeposit() internal returns (uint256 shares) {
        _fund(USDC, alice, DEPOSIT);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), DEPOSIT);
        shares = vault.deposit(DEPOSIT, alice);
        // Approve the vault (the share token is the vault itself) to pull alice's shares for requestRedeem.
        vault.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        assertGt(shares, 0, "alice got wallet shares");
        assertEq(vault.balanceOf(alice), shares, "wallet shares == balanceOf");
    }

    /// @dev Operator (this) fulfils alice's single pending USDC parcel of `shares`.
    function _operatorFulfill(uint256 shares) internal {
        address[] memory assets = new address[](1);
        uint256[] memory shs = new uint256[](1);
        address[] memory ctrls = new address[](1);
        assets[0] = USDC;
        shs[0] = shares;
        ctrls[0] = alice;
        vault.fulfillMultipleRedeems(assets, shs, ctrls);
    }

    // ====================================================================
    // (a) WALLET SHARES
    // ====================================================================

    /// @notice 1. Blocklisted holder of WALLET shares cannot self-exit by ANY path.
    function test_WalletShares_blocklisted_cannotExit() public {
        uint256 shares = _aliceDeposit();

        vault.blocklist(alice);

        // redeem (claimable path) -> _beforeWithdraw reverts on receiver=alice.
        // But there is no claimable yet => actually checkAccess(controller=alice) passes (alice is caller),
        // then _redeemAsset -> _calculateClaimableAssetsForShares == 0 => NothingToWithdraw.
        // To isolate the COMPLIANCE revert we redeem with receiver=alice; the FIRST guard hit in the
        // claimable redeem path that touches compliance is _beforeWithdraw, but that runs AFTER the
        // claimable lookup. Alice has no claimable, so the dominant revert is the empty-claimable guard.
        // We therefore assert the strongest compliance guards on the paths alice WOULD use to exit
        // wallet shares: transfer, requestRedeem, instantRedeem.

        // transfer wallet shares out -> _update(from=alice,to=clean): to!=0 => _ensureNotRestricted(alice) reverts.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IComplianceErrors.AddressBlocklisted.selector, alice));
        vault.transfer(cleanReceiver, shares);

        // requestRedeem (escrow path) -> _transfer(owner=alice, vault) => _update => _ensureNotRestricted(alice) reverts.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IComplianceErrors.AddressBlocklisted.selector, alice));
        vault.requestRedeem(USDC, shares, alice, alice, false);

        // instantRedeem to self -> _ensureNotRestricted(receiver=alice) reverts (UltraVault.instantRedeem L381).
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IComplianceErrors.AddressBlocklisted.selector, alice));
        vault.instantRedeem(USDC, shares, 0, alice, alice);

        // instantRedeem to a CLEAN receiver -> receiver passes, but controller=alice restricted => reverts (L383-384).
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IComplianceErrors.AddressBlocklisted.selector, alice));
        vault.instantRedeem(USDC, shares, 0, cleanReceiver, alice);

        // Wallet shares are still escrowed in alice's wallet, untouched.
        assertEq(vault.balanceOf(alice), shares, "wallet shares frozen in place, not moved");
    }

    /// @notice 2. With alice blocklisted, an OPERATOR cannot push her wallet shares out to a clean
    ///            receiver via instantRedeem: the controller restriction blocks it.
    function test_WalletShares_operatorCannotPushToCleanReceiver() public {
        uint256 shares = _aliceDeposit();

        // Alice authorizes the operator (this) so checkAccess(controller=alice) passes for the operator.
        vm.prank(alice);
        vault.setOperator(address(this), true);

        vault.blocklist(alice);

        // Operator drives instantRedeem(controller=alice, receiver=cleanReceiver).
        // checkAccess(alice) passes (operator approved); receiver clean passes; but controller=alice
        // is restricted => _ensureNotRestricted(controller) reverts (UltraVault.instantRedeem L383-384).
        vm.expectRevert(abi.encodeWithSelector(IComplianceErrors.AddressBlocklisted.selector, alice));
        vault.instantRedeem(USDC, shares, 0, cleanReceiver, alice);

        // Same for the async claimable redeem path: _beforeWithdraw checks controller too. There is no
        // claimable here, so to prove the controller gate specifically we route through requestRedeem,
        // which the operator also cannot do (the _transfer of alice's shares hits _update from-side gate).
        vm.expectRevert(abi.encodeWithSelector(IComplianceErrors.AddressBlocklisted.selector, alice));
        vault.requestRedeem(USDC, shares, alice, alice, false);

        assertEq(vault.balanceOf(alice), shares, "operator could not move alice's wallet shares");
    }

    /// @notice 3. Unblocklisting restores access: alice can requestRedeem -> operator fulfils ->
    ///            alice claims and receives assets. Proves the funds are NOT permanently stuck while
    ///            compliance is cooperative.
    function test_Unblocklist_restoresAccess() public {
        uint256 shares = _aliceDeposit();

        vault.blocklist(alice);
        // confirm blocked
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IComplianceErrors.AddressBlocklisted.selector, alice));
        vault.requestRedeem(USDC, shares, alice, alice, false);

        // Cooperative compliance: unblock.
        vault.unblocklist(alice);
        (bool blocked, bool frozen) = vault.restrictionStatus(alice);
        assertFalse(blocked, "unblocklisted");
        assertFalse(frozen, "not frozen");

        // Now alice can run the full async exit.
        vm.prank(alice);
        vault.requestRedeem(USDC, shares, alice, alice, false);
        assertEq(vault.balanceOf(alice), 0, "shares escrowed to vault");

        _operatorFulfill(shares);

        ClaimableRedeem memory cr = vault.getClaimableRedeem(USDC, alice);
        assertEq(cr.shares, shares, "claimable shares recorded");
        assertGt(cr.assets, 0, "claimable assets recorded");

        uint256 before = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertGt(assets, 0, "received assets on redeem");
        assertEq(IERC20(USDC).balanceOf(alice) - before, assets, "alice received the assets");
        // 1:1 oracle, zero fees => alice gets back her full deposit.
        assertApproxEqAbs(assets, DEPOSIT, 2, "full deposit returned after unblock");
    }

    /// @notice 4. forceBurn seizes WALLET shares irreversibly (value destroyed, never returned).
    function test_ForceBurn_seizesWalletShares() public {
        uint256 shares = _aliceDeposit();

        vault.blocklist(alice);

        uint256 totalBefore = vault.totalSupply();
        vault.forceBurn(alice, shares);

        assertEq(vault.balanceOf(alice), 0, "wallet shares destroyed");
        assertEq(vault.totalSupply(), totalBefore - shares, "totalSupply reduced by burned shares");
        // forceBurn destroys; there is no path that returns the burned value to alice.
        // (No re-mint API exists for a restricted address's destroyed shares.)
    }

    // ====================================================================
    // (b) PENDING REDEEM
    // ====================================================================

    /// @notice 5. Blocklisted MID-FLIGHT pending redeem: alice cannot self-cancel; the operator can
    ///            return the escrowed shares to alice's wallet via cancelRedeemRequestByOperator
    ///            (which bypasses the gate). The returned shares are still immovable while alice stays
    ///            blocklisted.
    function test_PendingRedeem_blocklistedMidFlight() public {
        uint256 shares = _aliceDeposit();

        // Alice escrows her shares into a pending redeem WHILE CLEAN.
        vm.prank(alice);
        vault.requestRedeem(USDC, shares, alice, alice, false);
        assertEq(vault.balanceOf(alice), 0, "shares escrowed");
        PendingRedeem memory pr = vault.getPendingRedeem(USDC, alice);
        assertEq(pr.shares, shares, "pending recorded");
        assertEq(vault.balanceOf(address(this)), 0, "operator holds no shares");

        // Now blocklist alice.
        vault.blocklist(alice);

        // Alice self-cancel -> UltraVault._handleRedeemRequestCancelation: _ensureNotRestricted(controller=alice) reverts.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IComplianceErrors.AddressBlocklisted.selector, alice));
        vault.cancelRedeemRequest(USDC, alice, alice);

        // Operator cancellation bypasses the gate: returns shares to alice's WALLET via super._update.
        uint256 returned = vault.cancelRedeemRequestByOperator(USDC, alice);
        assertEq(returned, shares, "operator returned pending shares");
        assertEq(vault.balanceOf(alice), shares, "shares back in alice's wallet");
        assertEq(vault.getPendingRedeem(USDC, alice).shares, 0, "pending cleared");

        // The returned shares are STILL immovable while alice is blocklisted (it's wallet value now).
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IComplianceErrors.AddressBlocklisted.selector, alice));
        vault.transfer(cleanReceiver, shares);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IComplianceErrors.AddressBlocklisted.selector, alice));
        vault.requestRedeem(USDC, shares, alice, alice, false);
    }

    // ====================================================================
    // (c) CLAIMABLE REDEEM
    // ====================================================================

    /// @notice 6. Blocklisted MID-FLIGHT claimable redeem: alice requested + operator fulfilled (claimable),
    ///            THEN blocklist. Alice cannot claim to self; operator cannot claim to a clean receiver
    ///            (controller restriction) -> claimable cannot be moved by ANYONE while blocklisted.
    ///            forceBurn does NOT reach claimable. Unblocklist makes claimable redeemable again.
    function test_ClaimableRedeem_blocklistedMidFlight() public {
        uint256 shares = _aliceDeposit();

        // Alice requests + operator fulfils WHILE CLEAN => claimable.
        vm.prank(alice);
        vault.requestRedeem(USDC, shares, alice, alice, false);
        _operatorFulfill(shares);

        ClaimableRedeem memory cr = vault.getClaimableRedeem(USDC, alice);
        assertEq(cr.shares, shares, "claimable shares recorded");
        uint256 owed = cr.assets;
        assertGt(owed, 0, "assets owed");

        // Now blocklist alice.
        vault.blocklist(alice);

        // Alice claim to self -> redeem -> _beforeWithdraw: _ensureNotRestricted(receiver=alice) reverts.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IComplianceErrors.AddressBlocklisted.selector, alice));
        vault.redeem(shares, alice, alice);

        // Operator tries to claim to a CLEAN receiver. Authorize operator first so checkAccess passes.
        vm.prank(alice);
        vault.setOperator(address(this), true);
        // redeem(controller=alice, receiver=cleanReceiver): _beforeWithdraw checks receiver (clean, ok)
        // then controller=alice (restricted) => reverts. Claimable cannot be moved by anyone.
        vm.expectRevert(abi.encodeWithSelector(IComplianceErrors.AddressBlocklisted.selector, alice));
        vault.redeem(shares, cleanReceiver, alice);

        // forceBurn does NOT reach claimable: alice holds 0 wallet shares, so forceBurn(alice, shares) reverts
        // (ERC20InsufficientBalance) and the claimable accounting is untouched.
        assertEq(vault.balanceOf(alice), 0, "no wallet shares to burn");
        vm.expectRevert(); // OZ ERC20InsufficientBalance — cannot burn wallet shares alice doesn't have
        vault.forceBurn(alice, shares);
        assertEq(vault.getClaimableRedeem(USDC, alice).assets, owed, "claimable untouched by forceBurn");

        // Cooperative compliance: unblock -> claimable becomes redeemable again.
        vault.unblocklist(alice);
        uint256 before = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertEq(assets, owed, "claimable fully redeemed after unblock");
        assertEq(IERC20(USDC).balanceOf(alice) - before, owed, "alice received owed assets");
    }
}
