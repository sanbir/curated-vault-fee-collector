# ADR-001 — Curated Vault Fee Collector (partner fees)

**Status**: Accepted (supersedes the earlier per-user-HWM design)
**Date**: 2026-06-04
**Owners**: P2P.org + Edge Capital (native vault fees), Partner (collector fees — the wallet/custody bringing end users)
**Related**: `Architecture.md`, `Implementation-plan.md`

---

## 1. Context

P2P.org and Edge Capital deploy curated **UltraYield** (ERC-7540 async) and **Fluid Lite** (ERC-4626 sync) vaults and charge the vaults' **existing native fees** (already implemented in those vaults). On top of each curated vault sits a thin **fee collector** whose fees accrue to a **Partner** (the wallet/custody platform that onboards end users).

The collector charges three partner fees and **nothing else**:

1. **Deposit fee** — a % of the deposit, taken when the user deposits.
2. **Withdrawal fee** — a % of the redeemed assets, taken at withdrawal.
3. **AUM fee** — a per-**block** fraction of assets under management, taken at withdrawal (measured by the number of blocks the assets were managed).

The earlier high-water-mark **performance fee** is **removed** — performance economics are handled by the underlying vaults' native fees. The collector is deliberately the **bare minimum** needed for the three fees plus partner-operated withdrawals.

---

## 2. Decision

### D1 — Three partner fees, paid directly to the partner in-asset
- Deposit fee skimmed from the incoming asset before depositing into the underlying → sent to `partner` immediately.
- Withdrawal fee + AUM fee skimmed from the asset returned by the underlying at withdrawal → sent to `partner`.
- **No fee-share pool, no `collectFees()` step** — fees leave to the partner at the moment they are charged. (This is a large simplification over the previous design.)

### D2 — AUM measured in blocks, deferred to withdrawal
- Each position stores a single `lastBlock` = the AUM accrual start. On withdrawal, `aumFee = assetsGross × aumFeePerBlock × (block.number − lastBlock) / 1e18`.
- **Top-ups** blend the start block share-weighted: `lastBlock = (oldShares·oldLastBlock + newShares·block.number) / (oldShares + newShares)`. This defers all AUM to withdrawal (no charge at deposit) while staying fair across tranches.
- **Partial withdrawals** leave `lastBlock` unchanged, so the remainder is charged for its full duration at its later exit. (Reviewed: blend + preserve is mathematically equivalent to per-tranche accrual.)

### D3 — Partner can withdraw on behalf of users; assets go to the user
- Both the user (`withdraw`/`withdrawAll`, async `requestRedeem`/`claim`) and the `partner` (`withdrawFor`/`withdrawAllFor`, async `requestRedeemFor`/`claimFor`) can exit any amount at any time.
- In **every** path the **net assets go to the user**; the partner only ever receives the fees. The partner cannot divert principal.

### D4 — Custody-only, non-transferable positions (retained)
The collector custodies the underlying shares and credits each user a non-transferable internal `Position{shares, lastBlock}`. No position token, no `transfer`. This is unchanged from before and keeps per-user accounting un-gameable.

### D5 — Two collectors sharing a base (sync vs async exit)
- `FluidLiteFeeCollector` — synchronous ERC-4626 exit (one tx).
- `UltraYieldFeeCollector` — ERC-7540 async: `requestRedeem` → operator fulfills on the underlying → `claim`; withdrawal + AUM fees charged at **claim** (AUM accrues through to claim).
- `CuratedFeeCollectorBase` holds the shared deposit, fee-settlement, admin, and partner logic; `FeeMath` is a tiny pure library (deposit/withdrawal %, per-block AUM).

### D6 — Caps enforced on the new value; standard safety
`Ownable2Step` owner (P2P) sets fees + partner + pause. Caps: `MAX_DEPOSIT_FEE = 5%`, `MAX_WITHDRAWAL_FEE = 5%`, `MAX_AUM_FEE_PER_BLOCK = 1e12` (WAD/block safety cap). `ReentrancyGuard` on all mutating entry points; `Pausable` gates deposits; fees round up (partner-favoring); fee total is clamped to the redeemed gross so the user net never underflows.

---

## 3. Alternatives considered
- **Keep the per-user HWM performance fee** — rejected: the underlying vaults already charge native performance/management fees; a second performance fee is redundant and far more complex (crystallization, fee-share pool, oracle-ratio tracking). Removing it is the explicit simplification requested.
- **Charge AUM at deposit (settle on top-up)** — rejected: requires realizing value mid-deposit; the share-weighted `lastBlock` defers all fee realization to withdrawal with less code.
- **Time-based (seconds) AUM** — rejected: the requirement is explicitly per-block.
- **Single collector for both vault types** — rejected: async vs sync exits differ; two thin contracts over a shared base are simpler to read and audit.

---

## 4. Consequences
**Positive**: minimal surface (≈360 lines across 4 files); fees go straight to the partner (no pool/claim bookkeeping); partner-operated withdrawals built in; reviewed fund-safe (partner can only ever take capped fees, never principal).

**Accepted**:
- **Pooled custody** — one collector holds all users' underlying shares; a collector bug is pool-wide. Mitigated by the small surface, reentrancy guards, and the adversarial review (0 confirmed findings).
- **AUM uses withdrawal-time value × blocks** (not a time-integral of value) — a deliberate simplification; AUM is charged on the value present at exit.
- **Async fees at claim** — for UltraYield the withdrawal + AUM fees are realized at `claim`; AUM accrues from the position start block through to claim.
- **Fee stack** — collector fees stack on top of the underlying vaults' native fees; both are intended. The collector charges its fees on the **actual** redeemed amount (i.e. net of the underlying's native fee).
