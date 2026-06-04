# Architecture — Curated Vault Fee Collector

> Companion to [ADR.md](./ADR.md) and [Implementation-plan.md](./Implementation-plan.md).

## 1. Component overview

```
                 end users                         partner (wallet / custody)
                    │ deposit / withdraw                │ withdrawFor / claimFor
                    ▼                                   ▼
   ┌─────────────────────────────────────────────────────────────┐
   │  Curated Fee Collector  (one per underlying vault)            │   partner
   │  • Position{shares, lastBlock} per user (NON-transferable)    │◄── deposit fee (asset, at deposit)
   │  • deposit% + withdrawal% + per-block AUM fees                │◄── withdrawal + AUM fee (asset, at withdrawal)
   │  • net assets ALWAYS go to the user                           │── net assets ─► user
   └───────────────┬─────────────────────────────────────────────┘
                   │ deposit / redeem / requestRedeem  (collector is holder & controller)
                   ▼
   ┌─────────────────────────────────────────────────────────────┐
   │  Curated underlying vault (UltraYield / Fluid Lite)           │
   │  charges its OWN native fees (P2P + Edge)                     │
   └─────────────────────────────────────────────────────────────┘
```

Two concrete collectors over a shared base + a tiny pure library:

| Contract | Underlying | Exit model | File |
|---|---|---|---|
| `FluidLiteFeeCollector` | sync ERC-4626 (fLiteUSD, iETHv2) | synchronous `withdraw` | `contracts/FluidLiteFeeCollector.sol` |
| `UltraYieldFeeCollector` | ERC-7540 async (UltraVault) | `requestRedeem` → operator fulfill → `claim` | `contracts/UltraYieldFeeCollector.sol` |
| `CuratedFeeCollectorBase` | — | deposit / fee-settlement / admin / partner auth | `contracts/CuratedFeeCollectorBase.sol` |
| `FeeMath` | — | pure: deposit/withdrawal %, per-block AUM | `contracts/libraries/FeeMath.sol` |

## 2. State

```solidity
struct Position { uint256 shares; uint256 lastBlock; } // lastBlock = AUM accrual start (share-weighted)
mapping(address => Position) _positions;
uint256 totalShares;

// async only (UltraYieldFeeCollector)
struct Pending { uint256 shares; uint256 lastBlock; }   // lastBlock carried from the position at request
mapping(address => Pending) pending;
uint256 totalPending;

// config
IERC4626 underlying; IERC20 asset;
address partner;                 // fee recipient AND authorized withdrawer-for-users
uint16 depositFeeBps; uint16 withdrawalFeeBps; uint256 aumFeePerBlock; // WAD/block
// caps: MAX_DEPOSIT_FEE=500 (5%), MAX_WITHDRAWAL_FEE=500 (5%), MAX_AUM_FEE_PER_BLOCK=1e12
```

Positions are an internal ledger — **no ERC-20/721 token, no `transfer`** — so they cannot be moved between addresses.

## 3. Fee math (`FeeMath`)

```
depositFee   = ceil(assets     * depositFeeBps    / 10_000)        // at deposit, on the deposited asset
withdrawalFee= ceil(assetsGross* withdrawalFeeBps / 10_000)        // at withdrawal, on the redeemed asset
aumFee       = ceil(assetsGross* aumFeePerBlock * blocksElapsed / 1e18)   // at withdrawal, by blocks held
```

`assetsGross` = the asset amount the collector actually receives from `underlying.redeem` (i.e. **net of the underlying's own native fee**). `blocksElapsed = block.number − lastBlock`. All fees round **up** (partner-favoring). On exit the partner cut is clamped to `assetsGross` (so the user net never underflows); in practice the 5% caps keep it well below.

**AUM start block (`lastBlock`)**
- First deposit: `lastBlock = block.number`.
- Top-up: `lastBlock = (oldShares·oldLastBlock + newShares·block.number) / (oldShares + newShares)` — share-weighted, defers AUM to withdrawal, fair across tranches.
- Partial withdrawal: `lastBlock` unchanged (the remainder keeps accruing from its original start).
- Async: the requested parcel carries the position's `lastBlock` (share-weighted across multiple requests); AUM accrues through to `claim`.

## 4. Flows

**Deposit** (both): pull `assets` → `depositFee` to partner → `underlying.deposit(assets−fee)` → credit `Position` (update weighted `lastBlock`, `shares += minted`).

**Sync withdraw** (`FluidLiteFeeCollector`): `withdraw(shares)` / `withdrawAll()` (user) or `withdrawFor(user, shares)` / `withdrawAllFor(user)` (partner). Reduce position → `underlying.redeem(shares)` → split `assetsGross` into withdrawal + AUM fee (to partner) and net (to the **user**).

**Async exit** (`UltraYieldFeeCollector`): `requestRedeem(shares)` (user) / `requestRedeemFor(user, shares)` (partner) move shares to `pending` and call `underlying.requestRedeem(…, collector, collector)`. After the operator fulfills on the underlying, `claim()` (user) / `claimFor(user)` (partner) `redeem` the fulfilled amount, split fees to partner, net to the **user**. No fee charged at request.

**Fees**: there is no separate collection step — the deposit fee is paid at deposit and the withdrawal + AUM fees at withdrawal/claim, directly to `partner`.

## 5. Security considerations
- **Net always to the user**: every exit (user- or partner-initiated) sends net assets to the position owner; the partner only ever receives fees → partner cannot take principal.
- **Per-user isolation**: exits are keyed to the position owner; positions are non-transferable.
- **Reentrancy**: `nonReentrant` on all mutating entry points; state updated before external `redeem`/`transfer` (CEI).
- **Caps on the new value** in `setFees`; fee total clamped to redeemed gross.
- **Access**: `Ownable2Step` owner (P2P) sets fees/partner/pause; `partner`-only for the `*For` withdrawals; the operator role for async fulfillment lives on the **underlying**, not here.
- **Reviewed**: adversarial review (fund-safety, accounting, simplicity) returned **0 confirmed findings**.

## 6. Addresses & environment (mainnet)
- fLiteUSD (Fluid Lite USD): `0x273DA948ACa9261043fbdb2a857BC255ECC29012` (asset = USDC).
- UltraYield: tested via a self-deployed real `UltraVault` on the fork.
- Fork RPC: `MAINNET_RPC_URL` env, else an archive-capable public fallback.
