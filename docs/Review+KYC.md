# Review + KYC — UltraYieldFeeCollector as the P2P depositor to UltraVault

> Companion to [ADR.md](./ADR.md) and [Architecture.md](./Architecture.md).
> **Date**: 2026-06-10
> **Scope**: (1) integration-review caveats for using `UltraYieldFeeCollector` as the partner depositor
> into UltraYield's `UltraVault`; (2) design options for adding KYC/allowlisting **on P2P's side**,
> alongside (or inside) the collector.
> **Context**: the partner thread requests a **KYC vault** with **per-partner deposit/platform/withdrawal
> fees** (banks/CEXes, fee tiers from ~5% up to 25–30%). UltraYield's own KYC-gated vault code is not yet
> published and waits on their next audit; their main `UltraVault` has ~46 bytes of bytecode headroom
> (EIP-170), so per-partner fee logic cannot live there. The collector is the natural home for both the
> partner fees and the KYC gate.

---

## 1. Integration review — what was verified

The collector was checked against the **current public UltraYield source**, not just its docs:

- `lib/ultrayield-src` is **byte-identical** to `UltraYield/UltraYield-contracts/src` (`diff -rq` clean), so
  the 4 UltraYield fork tests exercise exactly the code UltraYield publishes today.
- **Deposit**: `UltraVault.deposit()` is permissionless (`whenNotPaused` only) — the collector needs no role.
- **Exit request**: `requestRedeem(_shares, address(this), address(this))` passes the vault's
  `checkAccess(owner)` (collector is owner, controller, and caller). The vault pulls shares via
  `_spendAllowance(owner, address(this), shares)` — covered by the constructor's max share approval.
- **Claim**: `maxRedeem(controller)` returns the collector's claimable shares; the vault deducts **its own
  withdrawal fee at fulfillment** (`UltraVault._fulfillRedeem`, `convertedAssets − withdrawalFee`), so
  `redeem()` returns vault-net assets and the collector's partner fees layer cleanly on top — no
  double-charging, no fee-accounting drift.
- **No privileged role required**: tests replicate production — the **vault's** `OPERATOR_ROLE` (UltraYield
  ops) calls `fulfillRedeem(asset, shares, collector)` between request and claim; the collector just waits.

**Conclusion**: the collector works as a depositor against today's `UltraVault` with zero UltraYield code
changes and zero roles granted. The caveats below are the conditions and edges around that conclusion.

---

## 2. Caveats

### C1 — The KYC vault is the real gate (UltraYield dependency)

Everything verified above targets the **current permissionless** vault. The vault the partner thread
actually requests is the **KYC-gated** version, which is not in the public repo ("for a KYC vault we'll
have to finish the next audit"). Expected consequences:

- The KYC vault will almost certainly allowlist depositor addresses → the **collector's address must be
  allowlisted by UltraYield** (one-time admin action, not co-development).
- The integration must be **re-verified against the new code** when it lands: the collector pins a minimal
  ERC-7540 surface (`requestRedeem` / `redeem` / `maxRedeem` in `IUltraVault7540`), which is robust to
  additive changes but not to semantic ones (e.g. per-receiver checks inside `deposit`).
- **Important structural point**: with the collector in the middle, the vault only ever sees the
  **collector's address** — vault-level KYC cannot see end users. End-user KYC therefore **must** happen at
  the collector layer or off-chain at the partner. This is the core argument for §3.

### C2 — Redemption timing is controlled by UltraYield's operator

`fulfillRedeem` is `OPERATOR_ROLE`-only and the assets live off-vault at `fundsHolder` (Fordefi → CEXes).
Every exit settles only when UltraYield ops process the queue. This is inherent to the product (any
depositor, including UltraYield's own `UltraFeeder`, has it), but it means:

- The collector cannot give users any latency guarantee on exits.
- A halted/negligent operator strands pending exits (trust assumption on UltraYield ops, mitigated only by
  the jointly-held Fordefi/Safe governance discussed with the partner).
- Ops note: all collector users aggregate into **one controller position** on the vault — UltraYield's ops
  will see and fulfill it as one large redeem request.

### C3 — Base asset only

The collector uses only the base-asset paths (`deposit`, `requestRedeem`, `redeem`). `UltraVault` also
supports `depositAsset` / `requestRedeemOfAsset` / `redeemAsset` for any rate-provider-supported asset.
Acceptable for v1; a multi-asset partner flow would need new collector entry points (and per-asset pending
accounting, since the vault tracks pending/claimable **per controller per asset**).

### C4 — No cancellation path

The vault supports `cancelRedeemRequest(...)` / `cancelRedeemRequestPartially(...)`; the collector does not
expose them. Once a user requests, the shares sit pending until the operator fulfills. If a cancellation
feature is added later, note the vault's cancel is `checkAccess(controller)` — the collector (as
controller) can call it; the work is in re-crediting `Position`/`Pending` and the AUM `lastBlock` blending
in reverse.

### C5 — Pooled claimable: first-come-first-served claims

The vault tracks claimable per controller, i.e. **pooled across all collector users**. `_claim` takes
`min(user pending, total claimable)`, so a user whose own request was not yet fulfilled can claim from
liquidity fulfilled against another user's request. Everyone is eventually paid at the vault's blended
claimable rate (the vault pays proportionally from its `(assets, shares)` claimable parcel), so this is a
**fairness/ordering footnote, not a fund-safety issue** — but it should be stated to partners: claim
ordering inside the collector is FCFS, not request-order.

### C6 — Pause semantics: deposits pausable, exits not

`deposit` is `whenNotPaused`; `requestRedeem` / `claim` are not pausable. This is the right default — the
owner key **cannot trap user funds** — but it conflicts with a strict AML reading ("freeze suspicious
positions"). If partners (banks) require freeze capability, that is a **deliberate policy change**, not a
bug fix; see §3.5. Any freeze mechanism must be narrowly scoped (per-user flag, compliance role, events)
so the "exits cannot be globally trapped" property survives review.

### C7 — Fee caps vs the discussed partner tiers

`MAX_DEPOSIT_FEE = MAX_WITHDRAWAL_FEE = 500` bps (5%). The thread explicitly mentions partners at
**25–30%**. Raising the caps is a one-line constant change **per deployment decision**, but it materially
changes the trust statement in the README/ADR ("partner can only ever take the capped fees"): at 30% caps,
a mis-set fee is a 30% haircut. Recommendation: keep caps per-instance — deploy high-cap instances only
for the specific partners whose term sheets need them; do not raise the default.

### C8 — Immutability cuts both ways

The collector is non-upgradeable (`Ownable2Step`, no proxy). Good for the trust story; it also means **KYC
cannot be retrofitted into already-deployed instances**. Since the model is one instance per partner,
this is mostly a sequencing constraint: decide the KYC design **before** the first partner deployment, or
accept a v2 redeployment + user migration (withdraw → re-deposit, which re-triggers deposit fees unless
waived). The registry pattern in §3.4-D specifically decouples list management from collector immutability.

### C9 — Inherited trust in UltraVault (unchanged by the collector)

The collector does not alter the underlying trust model: `UltraVault` is timelocked-UUPS upgradeable by its
owner, pricing comes from UltraYield's oracle (`totalAssets` is oracle-driven), and deposited assets leave
to `fundsHolder` immediately. The collector trusts the vault's `deposit` return value for share crediting
and `redeem` return value for gross assets — both fine against the audited vault, but any vault upgrade is
silently inherited risk. Monitor the vault's upgrade-proposal events.

---

## 3. KYC / allowlisting on P2P's side

### 3.1 Why the collector layer is the right enforcement point

1. **The vault cannot see end users** (C1): all vault interactions come from the collector's address.
   Vault-level KYC ends at "the collector is allowlisted".
2. **Positions are non-transferable** (ADR D4): there is no share token that can circulate to a
   non-KYC'd wallet after deposit. An allowlist checked at deposit time is therefore *airtight* at this
   layer — unlike an ERC-4626 feeder, which would also need transfer restrictions on its share token.
3. **Per-partner instances** map 1:1 onto per-partner KYC policies (a bank's list ≠ a CEX's list).
4. **No bytecode pressure**: the collector is a small immutable contract; adding a gate costs nothing
   against EIP-170, unlike the 46-byte-margin `UltraVault`.

### 3.2 What must be gated

| Entry point | Gate target | Why |
|---|---|---|
| `deposit(_assets, _receiver)` | **`_receiver`** (beneficiary) and **`msg.sender`** (source of funds) | AML cares about both who owns the position and who funded it. Gating only `msg.sender` lets a KYC'd relayer credit anyone; gating only `_receiver` lets dirty funds in via a clean beneficiary. |
| `requestRedeem*` / `claim*` | **policy decision** — see §3.5 | Gating exits is a freeze, with very different trust implications than gating entries. |
| `requestRedeemFor` / `claimFor` (partner) | already `_onlyPartner` | The partner acting for the user is the existing semi-trusted path; no extra gate needed if the position itself was KYC-gated at entry. |

Default recommendation: **gate deposits only; exits always allowed** (to the user's own address). A
de-listed user can leave but cannot grow the position. Freezing is opt-in per §3.5.

### 3.3 Policy questions to answer before implementation

1. **De-listing semantics**: exit-only (recommended default) vs. full freeze (banks may demand it).
2. **List owner**: P2P (collector `owner`), the partner (they KYC their own users), or a dedicated
   compliance key? Recommendation: a separate `s_kycManager` per instance — partners run their own list,
   P2P retains override via `Ownable2Step` owner; do **not** reuse the fee-setting owner key day-to-day.
3. **Granularity**: per-instance lists (each partner isolated) vs. one shared registry (one attestation
   serves all P2P products). Drives the choice between approaches A/B and D below.
4. **Off-chain linkage**: whatever goes on-chain is just an address flag; the KYC file itself stays
   off-chain with the partner/provider. Emit events (`KycSet(address,bool,bytes32 refId)`) so the
   off-chain case ID is auditable without doxxing the user.

### 3.4 Allowlisting approaches considered

#### A — On-chain allowlist mapping inside the collector

```solidity
mapping(address => bool) internal s_allowed;          // managed by s_kycManager
error CuratedFeeCollector__NotAllowed(address account);

function deposit(uint256 _assets, address _receiver) external ... {
    if (!s_allowed[msg.sender] || !s_allowed[_receiver]) revert CuratedFeeCollector__NotAllowed(...);
    ...
}
```

- **Pros**: simplest to write, read, and audit; no external calls; gas = 1 cold `SLOAD` per check;
  per-partner isolation falls out of per-partner instances automatically.
- **Cons**: list management is **per instance** — 13 partners = 13 lists to operate; baked into the
  immutable collector (C8): policy changes (e.g. moving to attestations) require redeployment;
  on-chain add/remove tx per user per instance.
- **Fits when**: few partners, partner user counts are modest, policies are stable.

#### B — Partner-gated deposits (the partner is the KYC oracle)

Remove open `deposit`; only the partner can deposit on behalf of its KYC'd users:

```solidity
function depositFor(address _user, uint256 _assets) external { _onlyPartner(); ... }
```

- **Pros**: zero list infrastructure on-chain — the partner (bank/CEX) already KYCs its users off-chain
  and is contractually liable; mirrors how the partner-side `*For` exit functions already work; smallest
  possible diff.
- **Cons**: users cannot self-deposit (may be fine — bank/CEX users act through the partner's platform
  anyway); concentrates flow through one partner hot wallet (operational and AML-reporting bottleneck);
  P2P has no on-chain evidence of *which* end user was KYC'd beyond the partner's say-so — weaker answer
  to the thread's "AML objections" than an explicit per-address gate.
- **Fits when**: the partner fully owns the user relationship and end users never touch the chain
  directly. **Note**: A and B compose — partner-only deposits *plus* a receiver allowlist is the
  strictest cheap option.

#### C — Signature-based attestation (EIP-712 KYC vouchers)

The KYC service signs `(receiver, sender, instance, expiry, caseRef)` off-chain; `deposit` verifies the
signature and checks expiry. Optionally cache `s_allowed[receiver] = true` on first use.

- **Pros**: no per-user admin transactions — list maintenance is an off-chain signer; expiry gives
  re-KYC for free; one signer key can serve all instances and future products; pairs naturally with a
  web onboarding flow.
- **Cons**: revocation is weak — a signed voucher is valid until expiry unless a nonce/blocklist is added
  (which reintroduces storage and admin txs, eroding the benefit); signer key management becomes
  compliance-critical infrastructure; more verification code in the immutable contract (signature
  malleability/domain-separation audit surface; cf. the standard EIP-712 pitfalls).
- **Fits when**: high user volume, self-serve deposits, and an existing KYC backend that can run a signer.

#### D — External allowlist registry (recommended)

A separate, P2P-operated registry contract; collectors hold an immutable pointer and ask it:

```solidity
interface IKycRegistry {
    function isAllowed(address account, address instance) external view returns (bool);
}
// in the collector:
IKycRegistry internal immutable i_kycRegistry;   // address(0) = ungated instance
if (address(i_kycRegistry) != address(0)
    && (!i_kycRegistry.isAllowed(msg.sender, address(this))
        || !i_kycRegistry.isAllowed(_receiver, address(this)))) revert ...;
```

- **Pros**: **decouples policy from the immutable collector** (C8) — the registry can evolve (roles,
  attestations, expiry, per-partner sub-lists, even an ERC-3643-style identity backend later) without
  touching deployed collectors; one user attestation can cover all instances; the same registry serves
  the FluidLite collector and future products; the `address(0)` sentinel lets non-KYC instances reuse
  the same bytecode.
- **Cons**: one external `STATICCALL` per deposit (negligible vs. the vault deposit itself); the registry
  becomes a new trusted component — if it is upgradeable/admin-managed, "immutable collector" is no longer
  the whole trust story for gated instances (document this explicitly); registry downtime semantics must
  be chosen (revert-closed is correct for KYC).
- **Fits when**: more than ~2 partner instances or any expectation that KYC policy will evolve. Given the
  thread's "10 CEXes, 3 banks", this is the recommended shape.

#### E — Rely solely on UltraYield's upcoming KYC vault

Do nothing on P2P's side; wait for UltraYield's KYC vault and get the collector allowlisted.

- **Pros**: zero P2P work.
- **Cons**: **does not actually KYC end users** (C1 — the vault sees only the collector); timeline is
  hostage to UltraYield's next audit; per-partner policy still impossible at the vault layer. This option
  fails the thread's requirement on its own merits and is listed only for completeness.

#### F — Defense in depth (E + one of A–D)

UltraYield's KYC vault allowlists the **collector**; the collector (per A–D) allowlists **end users**.
Each layer enforces what only it can see. This is the end-state to aim for; until UltraYield ships, the
collector-side gate alone (A–D) is what answers the partner's "let's do a KYC vault / AML objections" ask
for flows that run through P2P's depositor.

#### Comparison

| | A mapping | B partner-only | C EIP-712 | D registry | E vault-only |
|---|---|---|---|---|---|
| End-user KYC enforced on-chain | ✓ | indirect | ✓ | ✓ | ✗ |
| Admin tx per user | 1/instance | 0 | 0 (signer) | 1 (all instances) | — |
| Revocation | immediate | immediate | weak (expiry/nonce) | immediate | — |
| Survives policy change w/o redeploy | ✗ | ✗ | partly | **✓** | — |
| New trusted component | none | partner | signer key | registry admin | UltraYield |
| Audit surface added | minimal | minimal | moderate (sig code) | small (iface + registry) | none |
| Fits 13+ partner instances | poorly | per-partner ✓ | ✓ | **✓** | — |

**Recommendation**: **D**, optionally composed with **B** for bank-type partners (partner-only deposits
*and* registry-checked receivers), targeting **F** once UltraYield's KYC vault ships. Implement as a
constructor-injected immutable registry pointer with an `address(0)` escape hatch so gated and ungated
instances share one audited bytecode.

### 3.5 Freeze (exit gating) — only if a partner contractually requires it

If a bank demands freeze, add a **narrow** per-user flag in the registry/collector checked in
`requestRedeem*` and `claim*`, controlled by a dedicated compliance role, always emitting an event with an
off-chain case reference. Keep it **off by default** and out of instances that don't need it (separate
deployment flag), so the "owner cannot trap user funds" property (C6) remains true for every instance
where it was promised. A frozen user's pending/claimable stays in the collector — funds are preserved,
only payout is delayed. Do **not** implement freeze by pausing exits globally.

### 3.6 Sequencing

1. Decide policy questions (§3.3) with the first 1–2 partners' compliance teams — this picks A–D.
2. Implement + audit the gate (small diff for A/B/D; C needs a focused signature review). The 0-findings
   adversarial review of the current code does **not** cover the gate.
3. Deploy per-partner gated instances; keep caps per C7.
4. When UltraYield's KYC vault ships: get collector addresses allowlisted, re-run the fork test suite
   against the new vault code (C1), and move to the defense-in-depth end state (F).

---

## 4. Open items

- [ ] Confirm with UltraYield how their KYC vault gates deposits (receiver allowlist? sender? both?) —
      determines whether the collector needs anything beyond being allowlisted (C1).
- [ ] Per-partner fee terms vs. the 5% caps (C7) — collect actual term sheets before minting high-cap instances.
- [ ] Decide de-listing semantics (exit-only vs freeze) per partner class (§3.3, §3.5).
- [ ] Cancellation support (C4) — product decision; non-trivial accounting if added.
- [ ] Multi-asset support (C3) — defer unless a partner needs non-base-asset flows.
- [ ] Monitoring: vault upgrade proposals, oracle updates, operator fulfillment latency (C2, C9).
