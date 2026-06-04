# Architecture — Curated Vault Fee Collector

> Companion to [ADR.md](./ADR.md) and [Implementation-plan.md](./Implementation-plan.md).

---

## 1. Component overview

```
                 end users
                    │  deposit(asset) / redeem|requestRedeem+claim
                    ▼
   ┌───────────────────────────────────────────────┐
   │  P2P Fee Collector  (one per underlying vault)  │   feeRecipient (P2P)
   │  • Position{shares, hwm} per user (NON-transfer)│◄── collectFees() (asset)
   │  • accruedFeeShares pool                        │
   │  • deposit/withdraw fee (asset) + perf fee(skim)│
   │  • HwmFeeMath (pure)                            │
   └───────────────┬───────────────────────────────┘
                   │ deposit / redeem / requestRedeem   (collector is the holder & controller)
                   ▼
   ┌───────────────────────────────────────────────┐
   │  Curated underlying vault (Edge)                │
   │  fLiteUSD (sync ERC-4626) | UltraVault (7540)   │── NAV via convertToAssets()
   │  reads P2P NAV oracle (UltraYield)              │   ← P2P oracle (UltraYield only)
   └───────────────────────────────────────────────┘
```

Two concrete collectors, one shared math library:

| Contract | Underlying | Exit model | File |
|---|---|---|---|
| `FluidLiteFeeCollector` | sync ERC-4626 (fLiteUSD, iETHv2) | synchronous `redeem` | `contracts/FluidLiteFeeCollector.sol` |
| `UltraYieldFeeCollector` | ERC-7540 (UltraVault) | async request→fulfill→claim | `contracts/UltraYieldFeeCollector.sol` |
| `HwmFeeMath` | — | — | `contracts/libraries/HwmFeeMath.sol` |

---

## 2. State

```solidity
struct Position {
    uint256 shares;   // underlying-vault shares attributed to this user (collector custodies them)
    uint256 hwm;      // high-water price = convertToAssets(SHARE_UNIT) at last crystallization (asset base-units / whole share)
}
mapping(address => Position) position;          // both collectors
uint256 accruedFeeShares;                       // perf-fee shares skimmed, awaiting collectFees()
uint256 totalManagedShares;                     // Σ position.shares + accruedFeeShares (invariant vs collector's underlying balance)

// async-only (UltraYieldFeeCollector)
struct Pending { uint256 shares; }              // requested, awaiting operator fulfillment
mapping(address => Pending) pending;

// config
IERC4626 underlying; IERC20 asset; uint256 SHARE_UNIT; // = 10**underlyingDecimals
uint16 depositFeeBps; uint16 withdrawFeeBps; uint16 perfFeeBps;
address feeRecipient;
// caps: MAX_DEPOSIT_FEE=500 (5%), MAX_WITHDRAWAL_FEE=200 (2%), MAX_PERFORMANCE_FEE=3000 (30%); BPS=10_000
```

Positions are an internal ledger — **no ERC-20/721 token, no `transfer`** — so HWM cannot leak across addresses.

---

## 3. Fee math (`HwmFeeMath`)

Let `curRatio = underlying.convertToAssets(SHARE_UNIT)` — asset base-units per one whole underlying share (already net of the underlying's own fees and incorporating P2P's NAV oracle for UltraYield).

```
// deposit
depositFee = mulDiv(assets, depositFeeBps, 10_000)            // round up (protocol-favoring)
netDeposit = assets - depositFee

// performance (per position), asset units
perfAssets = curRatio > hwm
    ? mulDiv((curRatio - hwm) * positionShares, perfFeeBps, SHARE_UNIT * 10_000)   // round down to user-favor on value, fee shares round up
    : 0
perfShares = mulDivUp(perfAssets, SHARE_UNIT, curRatio)        // shares worth perfAssets, round up
// crystallize: position.shares -= perfShares; accruedFeeShares += perfShares; hwm = max(hwm, curRatio)

// withdrawal (on exit), asset units
withdrawFee = mulDiv(assetsOut, withdrawFeeBps, 10_000)        // round up
netOut = assetsOut - withdrawFee  → user; withdrawFee → feeRecipient
```

**Invariants**
- `hwm` only increases (ratchet). A position below its `hwm` accrues **zero** perf fee until it recovers — true HWM.
- `hwm` is a **price**, untouched by changing `shares` (partial withdrawals preserve it).
- Two positions with different `hwm` at the same `curRatio` pay **different** perf fees → **not socialized**.
- `Σ position.shares + accruedFeeShares == underlying.balanceOf(collector)` (sync) / `+ Σ pending.shares` while requests are outstanding (async).

---

## 4. Flows

### 4.1 Deposit (both collectors)
1. `asset.transferFrom(user, collector, assets)`.
2. `(depositFee, net) = split`; `asset.transfer(feeRecipient, depositFee)`.
3. **Crystallize** existing position at `curRatio` (skim `perfShares` → `accruedFeeShares`).
4. `underlying.deposit(net, collector)` → `newShares`.
5. `position.shares += newShares`; `position.hwm = max(hwm, curRatio)` (first deposit: `hwm = curRatio`).

### 4.2 Sync withdraw (`FluidLiteFeeCollector`)
1. Crystallize position at `curRatio`.
2. `assetsOut = underlying.redeem(sharesToRedeem, collector, collector)`.
3. `(withdrawFee, net) = split`; `asset.transfer(feeRecipient, withdrawFee)`; `asset.transfer(receiver, net)`.
4. `position.shares -= sharesToRedeem`; `hwm` preserved.

### 4.3 Async exit (`UltraYieldFeeCollector`)
- `requestRedeem(shares)`: crystallize at `curRatio` (locks perf fee); `position.shares -= shares`; `pending.shares += shares`; `underlying.requestRedeem(shares, collector, collector)`.
- *(operator P2P/Edge calls `underlying.fulfillRedeem` on the underlying — out of collector scope.)*
- `claim(receiver)`: `assetsOut = underlying.redeem(pending.shares, collector, collector)`; withdrawal fee; net → receiver; clear pending. **No further perf fee** (locked at request).
- `cancelRequest()`: `underlying.cancelRedeemRequest`; move `pending.shares` back to `position.shares`.

### 4.4 Fee collection
`collectFees()`: redeem `accruedFeeShares` from the underlying to `feeRecipient` (sync immediate; async via request/claim by `feeRecipient`/owner). Resets `accruedFeeShares`.

---

## 5. Decimal handling
- `SHARE_UNIT = 10**underlying.decimals()` (fLiteUSD shares 18-dec; UltraVault shares = asset-dec).
- `curRatio` and `hwm` share the unit "asset base-units per whole share", so subtraction is exact.
- `perfAssets = (curRatio - hwm) * shares / SHARE_UNIT` keeps share-count scaling exact regardless of asset decimals.
- All `mulDiv` via OpenZeppelin `Math`; fee components round **up**, user payouts round **down**.

---

## 6. Security considerations
- **Reentrancy**: `nonReentrant` on deposit/withdraw/request/claim/collect; checks-effects-interactions (state updated before external `transfer`/`redeem`).
- **Pooled custody**: single collector custodies underlying shares; mitigated by minimal surface + immutable math + audits. `totalManagedShares` invariant asserted in tests.
- **NAV-oracle trust** (UltraYield): the collector trusts the underlying's `convertToAssets` (P2P-guardrailed/vested). It does not add a second oracle. A spiky price is bounded by the underlying's own jump/drawdown guardrails.
- **Fee caps**: enforced on the *new* value in `setFees` (avoids the iETHv2 old-value-check bug).
- **Fee-dodge**: positions non-transferable; HWM keyed to the owning address; cannot be reset by sending shares elsewhere; top-up uses crystallize-then-raise.
- **Rounding/dust**: protocol-favoring fee rounding; first-deposit safe because the collector tracks underlying shares 1:1 (no internal share minting → no ERC-4626 inflation attack on the collector).
- **Access control**: `Ownable2Step` for config; `feeRecipient` is the only fee sink; operator role for fulfillment lives on the *underlying*, not the collector.

---

## 7. Addresses & environment (mainnet)
- fLiteUSD (Fluid Lite USD vault): `0x273DA948ACa9261043fbdb2a857BC255ECC29012` (asset = USDC `0xA0b8…eB48`).
- iETHv2 (Fluid Lite ETH vault): `0xA0D3707c569ff8C87FA923d3823eC5D81c98Be78` (asset = stETH).
- UltraYield: tested via self-deployed real `UltraVault` on the fork (no canonical mainnet instance referenced here).
- Fork: pinned recent block; RPC via `MAINNET_RPC_URL` env or `https://ethereum-rpc.publicnode.com` fallback.

---

## 8. Out of scope (this repo)
Off-chain HWM indexer; NFT-position variant; KYC/identity-bound positions; per-user clone path; cross-chain. All are documented extension points in the options analysis.
