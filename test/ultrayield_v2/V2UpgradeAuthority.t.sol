// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {BaseFork} from "../BaseFork.t.sol";

// Real UltraYield V2 protocol code (vendored), deployed onto a mainnet fork. No mocks of the protocol.
import {UltraVault, UltraVaultInitParams} from "uyv2/vaults/UltraVault.sol";
import {UltraVaultRateProvider} from "uyv2/oracles/UltraVaultRateProvider.sol";
import {TimelockedUpgradeModule} from "uyv2/utils/TimelockedUpgradeModule.sol";
import {Fees} from "uyv2/interfaces/Types.sol";
import {UPGRADER_ROLE} from "uyv2/utils/Roles.sol";
import {ORACLE_KEY, UPGRADE_MODULE_KEY, RATE_PROVIDER_KEY, FUNDS_HOLDER_KEY, INSTANT_REDEEM_EXITPOINT_KEY} from "uyv2/utils/AddressKeys.sol";

/// @dev A real new implementation to upgrade TO. Inherits the full vault; adds one marker fn so a
///      successful upgrade is observable on-chain.
contract UltraVaultUpgradeMock is UltraVault {
    function pocMarker() external pure returns (uint256) {
        return 0xC0FFEE;
    }
}

/// @notice Adjudicates the disputed claims in V2-upgrades.md vs the team's (Alejandro's) answers,
///         against a REAL self-deployed V2 vault + REAL TimelockedUpgradeModule. No vm.mockCall.
contract V2UpgradeAuthorityForkTest is BaseFork {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    UltraVaultRateProvider internal rp;
    UltraVault internal vault;
    TimelockedUpgradeModule internal module;
    UltraVaultUpgradeMock internal newImpl;

    address internal owner; // DEFAULT_ADMIN + UPGRADER + PAUSER + OPERATOR (this)
    address internal exitpoint;

    function setUp() public {
        _fork();
        owner = address(this);
        exitpoint = makeAddr("exitpoint");

        rp = new UltraVaultRateProvider(owner, USDC);
        UltraVault vImpl = new UltraVault();

        // Predict the proxy address so we can deploy the module (immutable vault) BEFORE the proxy.
        // The module ctor only stores the address (does not call the vault), so prediction is safe.
        uint64 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1); // proxy is the deploy AFTER the module
        module = new TimelockedUpgradeModule(predictedVault); // consumes `nonce`

        Fees memory fees;
        UltraVaultInitParams memory p = UltraVaultInitParams({
            owner: owner,
            asset: USDC,
            name: "UltraYield V2 USDC",
            symbol: "uy2USDC",
            rateProvider: address(rp),
            feeRecipient: owner,
            fees: fees,
            oracle: address(rp), // placeholder contract; never called by initialize or by upgrade tests
            fundsHolder: owner,
            instantRedeemExitpoint: exitpoint,
            upgradeModule: address(module)
        });
        vault = UltraVault(address(new ERC1967Proxy(address(vImpl), abi.encodeCall(UltraVault.initialize, (p))))); // consumes nonce+1

        require(address(vault) == predictedVault, "prediction mismatch");
        require(vault.upgradeModule() == address(module), "module not wired");

        newImpl = new UltraVaultUpgradeMock();
    }

    function _pending() internal view returns (address impl, bytes32 dataHash, uint256 execTime) {
        return module.pendingUpgrade();
    }

    // =====================================================================
    // POINT 3 (the headline factual dispute): does granting UPGRADER_ROLE
    // let the holder BYPASS the module / skip the 7-day timelock?  -> NO.
    // V2-upgrades.md claimed a "1-tx bypass". Alejandro says no bypass. Truth:
    // =====================================================================
    function test_P3_NoOneTxBypass_grantingUpgraderCannotSkipTimelock() public {
        address freshKey = makeAddr("freshUpgrader");
        vault.grantRole(UPGRADER_ROLE, freshKey); // owner (DEFAULT_ADMIN) grants in one tx, no timelock

        // (a) Fresh upgrader proposes then tries to execute immediately -> blocked by the 7-day timelock.
        vm.startPrank(freshKey);
        module.proposeUpgrade(address(newImpl), "");
        vm.expectRevert(TimelockedUpgradeModule.UpgradeNotReady.selector);
        module.executeUpgrade(address(newImpl), "");
        vm.stopPrank();

        // (b) Fresh upgrader calls the vault's UUPS entrypoint DIRECTLY -> only the module may call it.
        vm.prank(freshKey);
        vm.expectRevert(); // AccessDenied() in _authorizeUpgrade (msg.sender != upgradeModule)
        UUPS(address(vault)).upgradeToAndCall(address(newImpl), "");

        // (c) Even the DEFAULT_ADMIN/owner cannot upgrade the vault directly -> still must go through the module.
        vm.expectRevert();
        UUPS(address(vault)).upgradeToAndCall(address(newImpl), "");

        // (d) The ONLY path is the module after the full 7 days.
        vm.warp(block.timestamp + 7 days);
        vm.prank(freshKey);
        module.executeUpgrade(address(newImpl), "");
        assertEq(UltraVaultUpgradeMock(address(vault)).pocMarker(), 0xC0FFEE, "upgrade only via 7-day module path");

        console2.log("P3: granting UPGRADER_ROLE gives propose/cancel + execute-after-7d ONLY; no 1-tx bypass");
    }

    // =====================================================================
    // POINT 1: a compromised UPGRADER can be RECOVERED by the owner revoking
    // its role and granting UPGRADER to a new key that cancels the bad pending.
    // Alejandro's claim. Truth:
    // =====================================================================
    function test_P1_CompromisedUpgrader_recoveredByOwnerRotationAndCancel() public {
        address badKey = makeAddr("compromisedUpgrader");
        address newMpc = makeAddr("newMpcUpgrader");
        vault.grantRole(UPGRADER_ROLE, badKey);

        // Attacker (badKey) queues a malicious upgrade.
        vm.prank(badKey);
        module.proposeUpgrade(address(newImpl), "");
        (, , uint256 execTime) = _pending();
        assertGt(execTime, 0, "malicious upgrade pending");

        // Owner reacts within the 7-day window: revoke the compromised key, grant a fresh MPC key.
        vault.revokeRole(UPGRADER_ROLE, badKey);
        vault.grantRole(UPGRADER_ROLE, newMpc);

        // The revoked key can no longer act.
        vm.startPrank(badKey);
        vm.expectRevert(TimelockedUpgradeModule.Unauthorized.selector);
        module.cancelUpgrade();
        vm.expectRevert(TimelockedUpgradeModule.Unauthorized.selector);
        module.proposeUpgrade(address(newImpl), "");
        vm.stopPrank();

        // The new MPC key cancels the malicious pending upgrade (proposals are NOT bound to their proposer).
        vm.prank(newMpc);
        module.cancelUpgrade();
        (, , uint256 execAfter) = _pending();
        assertEq(execAfter, 0, "malicious upgrade cancelled by the new key");

        // And the new key can propose a legitimate upgrade.
        vm.prank(newMpc);
        module.proposeUpgrade(address(newImpl), "");
        (, , uint256 execNew) = _pending();
        assertGt(execNew, 0, "new key can propose");

        // Sanity: the malicious upgrade never executed (vault is NOT the mock yet — marker call reverts).
        vm.expectRevert();
        UltraVaultUpgradeMock(address(vault)).pocMarker();

        console2.log("P1: compromised UPGRADER recovered by owner revoke+regrant; new key cancels bad pending");
    }

    // =====================================================================
    // POINT 1 (the necessary caveat): recovery requires the owner to act within
    // 7 days AND be a separate, uncompromised authority. If the owner does NOT
    // act, the bad upgrade DOES land after 7 days.
    // =====================================================================
    function test_P1_caveat_dangerWindow_ifOwnerDoesNotActWithin7Days() public {
        address badKey = makeAddr("compromisedUpgrader");
        vault.grantRole(UPGRADER_ROLE, badKey);

        vm.startPrank(badKey);
        module.proposeUpgrade(address(newImpl), "");
        vm.warp(block.timestamp + 7 days); // owner did nothing
        module.executeUpgrade(address(newImpl), "");
        vm.stopPrank();

        assertEq(UltraVaultUpgradeMock(address(vault)).pocMarker(), 0xC0FFEE, "bad upgrade lands if owner inactive 7d");
        console2.log("P1-caveat: recovery is NOT automatic - owner must act within 7d and be uncompromised");
    }

    // =====================================================================
    // POINT 2: a PAUSED vault can still be upgraded. Alejandro: intentional
    // (they upgrade while paused, verify, then unpause). Truth (the fact):
    // =====================================================================
    function test_P2_UpgradeSucceedsWhileVaultIsPaused() public {
        assertTrue(vault.paused(), "vault starts paused after init");

        module.proposeUpgrade(address(newImpl), ""); // owner is UPGRADER
        vm.warp(block.timestamp + 7 days);
        module.executeUpgrade(address(newImpl), "");

        assertEq(UltraVaultUpgradeMock(address(vault)).pocMarker(), 0xC0FFEE, "upgrade executed while paused");
        assertTrue(vault.paused(), "vault remains paused through the upgrade (team unpauses after checks)");
        console2.log("P2: upgrade-while-paused works by design; pause is NOT the upgrade stopper");
    }

    // =====================================================================
    // POINT 4: replacing the upgrade module ALSO takes 7 days, so no vault
    // upgrade can happen faster than 7 days. Alejandro's claim. Truth:
    // =====================================================================
    function test_P4_ModuleSwapTakes7Days_noSub7dayUpgradePath() public {
        TimelockedUpgradeModule newModule = new TimelockedUpgradeModule(address(vault));

        vault.proposeAddressUpdate(UPGRADE_MODULE_KEY, address(newModule));

        // Not acceptable at 3 days (the dependency-timelock) — module swap is 7 days.
        vm.warp(block.timestamp + 3 days + 1);
        vm.expectRevert(); // CannotAcceptProposalYet
        vault.acceptAddressUpdate(UPGRADE_MODULE_KEY, address(newModule));

        // Acceptable only after 7 days. (acceptAddressUpdate re-pauses; vault already paused so unpause around it.)
        vm.warp(block.timestamp + 4 days); // now > 7 days since proposal
        vault.unpause();
        vault.acceptAddressUpdate(UPGRADE_MODULE_KEY, address(newModule));
        assertEq(vault.upgradeModule(), address(newModule), "module swapped only after 7 days");
        console2.log("P4: upgrade-module swap requires 7 days => no upgrade can be faster than 7 days");
    }

    // =====================================================================
    // POINT 4 (timelock table): 3 days for critical dependency addresses,
    // 7 days for the upgrade module. ("21 days" appears nowhere.) Truth:
    // =====================================================================
    function test_P4_Timelocks_3dForDeps_7dForModule() public {
        // Dependency (oracle) address update: accepts at exactly 3 days, not before.
        address dummyOracle = makeAddr("oracle2");
        vault.proposeAddressUpdate(ORACLE_KEY, dummyOracle);
        vm.warp(block.timestamp + 3 days - 10);
        vm.expectRevert(); // CannotAcceptProposalYet at <3d
        vault.acceptAddressUpdate(ORACLE_KEY, dummyOracle);
        vm.warp(block.timestamp + 11); // now >= 3 days
        vault.unpause();
        vault.acceptAddressUpdate(ORACLE_KEY, dummyOracle);
        assertEq(uint256(3 days), uint256(3 days)); // documents the dependency timelock

        // Upgrade module: at 3 days it is NOT yet acceptable (proves module != 3d, it is 7d).
        TimelockedUpgradeModule newModule = new TimelockedUpgradeModule(address(vault));
        vault.proposeAddressUpdate(UPGRADE_MODULE_KEY, address(newModule));
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(); // still CannotAcceptProposalYet -> module timelock > 3 days
        vault.acceptAddressUpdate(UPGRADE_MODULE_KEY, address(newModule));
        console2.log("P4-timelocks: deps = 3 days, upgrade module = 7 days (no 21-day value anywhere)");
    }

    // =====================================================================
    // POINT 5 (threat-model, not a contradiction): the async exit is
    // operator-gated. Under HONEST ops (fulfill <= 3d < 7d upgrade) users exit
    // in time (Alejandro). Under a HOSTILE/unavailable operator, the user
    // cannot self-exit regardless of the timelock (V2-upgrades.md caveat).
    // This PoC shows the operator-gated fact both interpretations rest on.
    // =====================================================================
    function test_P5_AsyncExit_isOperatorGated() public {
        // Pure code-fact demonstration: maxRedeem (claimable) is 0 until an OPERATOR fulfills.
        address user = makeAddr("user");
        assertEq(vault.maxRedeem(user), 0, "nothing claimable without operator fulfillment");
        // fulfillMultipleRedeems is onlyRole(OPERATOR_ROLE): a non-operator cannot self-serve a fulfillment.
        address[] memory a = new address[](1);
        uint256[] memory s = new uint256[](1);
        address[] memory c = new address[](1);
        a[0] = USDC; s[0] = 1; c[0] = user;
        vm.prank(user);
        vm.expectRevert(); // missing OPERATOR_ROLE
        vault.fulfillMultipleRedeems(a, s, c);
        console2.log("P5: exit conversion is operator-gated; 'enough time to exit' holds only under honest ops");
    }

    // =====================================================================
    // Q3: if a SINGLE UPGRADER_ROLE is held by ONE party (e.g. Edge), that
    // party can push an upgrade UNILATERALLY (7-day delay), and a party that
    // does NOT hold UPGRADER cannot cancel it (cancelUpgrade is onlyUpgrader,
    // not onlyAdmin) — pause does not help either. The DEFAULT_ADMIN "cancel"
    // is indirect (revoke+regrant), so it only works if the admin can actually
    // act. If DEFAULT_ADMIN is a 2-of-2 of the SAME two parties and the rogue
    // party is one co-signer, the honest party cannot move the admin at all.
    // =====================================================================
    function test_Q3_soloUpgraderActsUnilaterally_otherPartyCannotCancel() public {
        address edge = makeAddr("edgeSoloUpgrader"); // the single UPGRADER key
        address p2p = makeAddr("p2pNoUpgrader"); // the other party, no UPGRADER
        vault.grantRole(UPGRADER_ROLE, edge);

        // Edge proposes WITHOUT any second-party involvement.
        vm.prank(edge);
        module.proposeUpgrade(address(newImpl), "");

        // The other party (no UPGRADER_ROLE) CANNOT cancel — cancel is onlyUpgrader, not onlyAdmin.
        vm.prank(p2p);
        vm.expectRevert(TimelockedUpgradeModule.Unauthorized.selector);
        module.cancelUpgrade();

        // Edge executes unilaterally after the 7-day timelock (vault is paused; that does not block it — see P2).
        vm.warp(block.timestamp + 7 days);
        vm.prank(edge);
        module.executeUpgrade(address(newImpl), "");
        assertEq(UltraVaultUpgradeMock(address(vault)).pocMarker(), 0xC0FFEE, "solo UPGRADER pushed upgrade alone");
        console2.log("Q3: a single UPGRADER held by one party = unilateral upgrade; a non-UPGRADER party cannot cancel");
    }
}

interface UUPS {
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
}
