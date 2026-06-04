# ADR-001 — Curated Vault Fee Collector (per-user HWM)

**Status**: Accepted
**Date**: 2026-06-03
**Owners**: P2P.org (NAV oracle + fee operator), Edge Capital (curator of the underlying vaults)
**Related**: `../../UltraYield/FluidLite+UltraYield-fee-proxies.md` (options analysis), `../../UltraYield/FluidLite-vs-UltraYield-fee-models.md` (underlying fee models)

---

## 1. Context

P2P.org partners with Edge Capital. Edge curates newly deployed **UltraYield** (ERC-4626 + ERC-7540 async-redeem) and **Fluid Lite** (ERC-4626 synchronous) vaults; P2P runs the NAV oracle. On top of these curated vaults, P2P must charge **end users**:

1. a **deposit fee**,
2. a **withdrawal fee**, and
3. a **performance fee measured against each user's *individual* high-water mark (HWM)** — explicitly **not** socialized across the pool.

The underlying vaults cannot provide per-user HWM: their shares are fungible ERC-20s and they track at most a single **global** HWM (UltraYield `fees.highwaterMark`; iETHv2 `revenueExchangePrice`; fLiteUSD none). A fungible share token fundamentally cannot carry per-holder HWM — it resets/leaks on transfer (verified: the underlying share tokens have no transfer hook). Therefore a **separate fee layer** is required.

The prior options analysis concluded: **one shared proxy per vault is sufficient; per-user proxy instances are not required** and add gas/ops cost for benefits (custody isolation) that are largely illusory because the underlying vault pools funds regardless. The genuinely hard constraint is **position representation**: per-user HWM requires positions that are **non-transferable** or **NFT-bound**, never a fungible balance.

---

## 2. Decision

### D1 — One shared collector contract per underlying vault (not per-user instances)
Per-user HWM is per-user **state**, tracked in a `mapping(address => Position)`. Crystallization is **lazy** (only when the user transacts) so there is never an O(N) sweep. Per-user EIP-1167 clones are rejected: they add a deploy-gas tax + N-contract operations + a registry/upgrade burden, and do not segregate the commingled underlying funds. (See options doc §3–§4.) A per-user clone is reserved only for a future client with a hard *legal* custody-segregation requirement — which is really a separate underlying vault, not a clone.

### D2 — Two separate collectors sharing one math library
Because UltraYield exits are **asynchronous** (ERC-7540 `requestRedeem` → operator `fulfillRedeem` → `redeem`/claim) while Fluid Lite exits are **synchronous**, a single contract trying to serve both is more complex than two focused ones. We ship:

- **`FluidLiteFeeCollector`** — synchronous; wraps any synchronous ERC-4626 (fLiteUSD, iETHv2).
- **`UltraYieldFeeCollector`** — asynchronous; wraps UltraYield's ERC-7540 vault, acting as the single `controller`/`owner` and keeping an internal per-user redeem ledger.
- **`HwmFeeMath`** — a pure library with the shared deposit/withdrawal/HWM-performance arithmetic, identical across both.

This directly follows the partner guidance ("separate implementations if it makes it easier").

### D3 — Non-transferable, custody-only positions
End users **never hold the underlying vault shares**; the collector holds them and credits the user an internal, **non-transferable** position. This is the only robust defense against the fungible-transfer fee-dodge. (No ERC-20 position token is minted; positions are an internal ledger with view getters. An NFT-position variant is a documented future option if composability is ever required — it keeps the single-contract footprint.)

### D4 — HWM is a price ratio, in "asset base-units per whole underlying share"
For each position we store `hwm = convertToAssets(SHARE_UNIT)` at last crystallization, where `SHARE_UNIT = 10**underlyingShareDecimals`. HWM is a **price**, so deposits/withdrawals don't corrupt it, and it ratchets **up only**. The current ratio is read from the underlying's own `convertToAssets(SHARE_UNIT)` — which already incorporates P2P's NAV oracle for UltraYield and the auto-accrued exchange price for fLiteUSD — so the collector needs **no separate oracle integration**.

### D5 — Performance fee is *skimmed in shares*; deposit/withdrawal fees are taken *in asset*
- **Deposit fee**: skimmed from the incoming asset before depositing into the underlying; sent to `feeRecipient` immediately (asset units).
- **Withdrawal fee**: skimmed from the asset returned by the underlying on exit; sent to `feeRecipient` (asset units).
- **Performance fee**: on crystallization, the owed amount (in asset units, = `perfBps × gainAboveHWM`) is converted to underlying **shares** at the current ratio and **moved out of the user's position into an `accruedFeeShares` pool** held by the collector. This mirrors the underlying vaults' "skim" approach (no new token minted, no dilution of the user's *price* — only their share count drops). `feeRecipient` later calls `collectFees()` to redeem the pool.

### D6 — Crystallization rules
- **On any deposit top-up**: crystallize the pending performance fee on the existing position at the current ratio **first**, *then* add the new shares and set `hwm = max(hwm, currentRatio)`. Naive `hwm = max(hwm, ratio)` without crystallizing first would *forgive* the un-crystallized gain — explicitly avoided.
- **On withdrawal / redeem request**: crystallize on the full position first, then process the exit. `hwm` (a price) is **preserved** across partial withdrawals.
- **Async (UltraYield)**: crystallize at **`requestRedeem` time** (lock the fee at the request-time ratio). Rationale: UltraYield's NAV is conservative/vested and the exit value is fixed at fulfillment anyway; locking at request keeps the per-user ledger simple and avoids fulfillment-time NAV ambiguity. (Documented tradeoff vs. crystallize-at-fulfillment.)

### D7 — Fee caps enforced on the *new* value
`setFees` reverts if any new rate exceeds its cap (`MAX_DEPOSIT_FEE = 5%`, `MAX_WITHDRAWAL_FEE = 2%`, `MAX_PERFORMANCE_FEE = 30%`, all in BPS). This avoids the iETHv2 bug where `updateFees` validated the *old* storage value, leaving fees effectively uncapped.

### D8 — Roles & safety
`Ownable2Step` owner (governance) sets fees/recipient and pauses; `feeRecipient` receives fees. `ReentrancyGuard` on every external mutating entry point; `Pausable` gates deposits. All external interactions follow checks-effects-interactions. Fee rounding favors the protocol (round perf-fee shares up, round user payouts down) via OZ `Math.mulDiv`.

### D9 — No mocks in tests; mainnet fork at a pinned recent block
- `FluidLiteFeeCollector` is tested against the **live fLiteUSD** vault (`0x273D…9012`) on a mainnet fork; real yield is realized by `vm.warp`-ing forward (fLiteUSD auto-accrues), and **two users entering at different ratios prove the fee is not socialized**.
- `UltraYieldFeeCollector` is tested against a **self-deployed real UltraYield** instance on the fork (the actual `UltraVault`/`UltraVaultOracle`/`UltraVaultRateProvider` source — not a mock), where the test controls the NAV oracle to drive the price **up and down**, exercising the HWM gate across a real drawdown, and the async request→fulfill→claim lifecycle.
- `HwmFeeMath` is covered by exhaustive deterministic unit tests (above/at/below HWM, top-up, partial-withdraw preservation, multi-user non-socialization, zero/dust/boundary). `vm.mockCall` is not used anywhere.

---

## 3. Alternatives considered

| Alternative | Why rejected |
|---|---|
| **Per-user proxy instances (EIP-1167 clones)** | Deploy-gas tax + N-contract ops + registry/upgrade burden; custody isolation illusory (funds pool in the underlying vault regardless); clones are not legal separate accounts. Per-user HWM is achievable with 1 SSTORE/deposit in a shared contract. |
| **Single collector for both vault types** | Async vs sync lifecycles diverge enough that one contract is harder to reason about and audit than two focused ones. (Partner guidance favored separation.) |
| **Fungible ERC-20 position token** | Breaks per-user HWM on transfer (trivial fee-dodge). Non-transferable ledger or NFT required. |
| **Modify the underlying vault to track per-user HWM** | Impossible while shares remain fungible/transferable; also Edge owns the underlying, P2P owns the fee layer — separation of concerns. |
| **Separate P2P oracle integration in the collector** | Unnecessary: `convertToAssets` already reflects P2P's oracle (UltraYield) / accrued price (fLiteUSD). Reusing it removes a trust/integration surface. |
| **Crystallize perf fee off a spot NAV** | A single spiky oracle print could over-bill. Mitigated by reusing the underlying's already-guardrailed/vested price and by `hwm` ratchet semantics. |

---

## 4. Consequences

**Positive**: minimal footprint (1 contract per vault); cheapest correct per-user HWM; no dilution of honest holders; reuses the underlying's guardrailed NAV; clean audit surface; fork-tested against real liquidity with no mocks.

**Negative / accepted**:
- **Pooled custody / blast radius**: one collector holds all users' underlying shares; a collector bug is pool-wide. Mitigated by a small, audited, reentrancy-guarded core and immutable fee math.
- **Async second queue**: `UltraYieldFeeCollector` maintains its own per-user pending/claimable ledger on top of UltraYield's queue (added complexity, bounded).
- **Off-chain verifiability**: per-user HWM must be reconstructed from events (vs. reading one global value). Mitigated by `HWMSnapshot`/crystallization events + an off-chain indexer (out of scope for this repo).
- **Request-time crystallization** for async means the perf fee is computed at request-time NAV, not fulfillment NAV (documented).
- **Fee-stack ordering — RESOLVED**: the new curated vaults are **configured fee-free at the underlying**, so the collector is the sole fee layer (no double-charging). This is proven by tests: against the fee-free `fUSDC` underlying a grown redeem returns the collector's accounted NAV to the wei (the underlying skims nothing), and value conservation holds (principal + yield == user + collector fees). The self-deployed UltraYield vault is likewise initialized with zero `Fees`. The collector still measures the ratio via `convertToAssets` (net of any underlying fee), so it remains correct even if a future underlying is not fee-free.

---

## 5. Open questions (for the partnership, not blockers)

1. Are end users issued any transferable receipt at all, or is the non-transferable ledger acceptable for the product UX? (This repo assumes non-transferable.)
2. Is the async perf fee acceptable at request-time NAV, or must it be fulfillment-time? (This repo: request-time; switch is localized.)
3. Should deposit fee be waived in favor of a revenue-share of Edge's fee (optics)? (Out of scope; the contract supports any configured BPS incl. 0.)
