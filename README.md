# Curated Vault Fee Collector

A thin **partner fee layer** on top of curated **UltraYield** (ERC-7540 async) and **Fluid Lite** (ERC-4626 sync)
vaults. The underlying vaults keep their **own native fees** (charged by P2P + Edge); this layer adds three
fees that accrue to a **Partner** (the wallet/custody platform that brings end users):

- **deposit fee** — % of the deposit, taken at deposit time;
- **withdrawal fee** — % of redeemed assets, taken at withdrawal;
- **AUM fee** — a per-**block** fraction of assets under management, taken at withdrawal.

Both the **user** and the **partner** can withdraw any amount at any time — and in every case the **net assets go
to the user, the fees to the partner**. There is no performance/high-water-mark fee (handled by the underlying
vaults) and no fee-collection step (fees are paid straight to the partner when charged).

See [`docs/ADR.md`](docs/ADR.md), [`docs/Architecture.md`](docs/Architecture.md),
[`docs/Implementation-plan.md`](docs/Implementation-plan.md).

## Contracts (`contracts/`)

| Contract | Underlying | Exit model |
|---|---|---|
| `FluidLiteFeeCollector` | synchronous ERC-4626 (fLiteUSD, iETHv2) | one-tx `withdraw` / `withdrawFor` |
| `UltraYieldFeeCollector` | ERC-7540 async (UltraYield `UltraVault`) | `requestRedeem` → operator fulfill → `claim` (+ `*For` partner variants) |
| `CuratedFeeCollectorBase` | — | shared deposit / fee-settlement / admin / partner auth |
| `libraries/FeeMath` | — | pure: deposit/withdrawal %, per-block AUM |

The collector custodies the underlying shares and tracks a **non-transferable** per-user `Position{shares, lastBlock}`.
`lastBlock` is the AUM accrual start (share-weighted across top-ups), so AUM is deferred to withdrawal and fair
across tranches. `Ownable2Step` owner (P2P) sets fees/partner/pause; caps: deposit ≤ 5%, withdrawal ≤ 5%,
`aumFeePerBlock ≤ 1e12` (WAD/block). `ReentrancyGuard` + `Pausable`; fees round up; the partner cut is clamped to
the redeemed gross.

## Tests — mainnet fork, no mocks

22 tests, **no `vm.mockCall`**:

- `test/unit/FeeMath.t.sol` — deposit/withdrawal % + per-block AUM math, incl. fuzz (AUM monotonic in blocks, fee ≤ amount).
- `test/fluidlite/FluidLiteFeeCollector.t.sol` — live **fLiteUSD** vault: deposit fee → partner; withdrawal + AUM
  fee → partner with net → user; **partner-initiated** `withdrawAllFor` (net to the user); AUM scales with blocks
  (`vm.roll`); no-AUM same block; top-up blends the start block; partial withdraw preserves it; caps/access/pause/
  custody-only. (Expected fees use `previewRedeem`, which accounts for fLiteUSD's own native withdrawal fee.)
- `test/ultrayield/UltraYieldFeeCollector.t.sol` — **self-deployed real UltraYield** vault: deposit fee; full async
  request → operator-fulfill → claim with withdrawal + AUM fees charged at claim; partner `requestRedeemAllFor` /
  `claimFor` (net to the user); `onlyPartner` guard.

### Run

```bash
export MAINNET_RPC_URL=https://your-archive-rpc   # optional; archive fallback used otherwise
forge test -vv
```

### Latest result

```
6 unit + 12 fLiteUSD (live) + 4 UltraYield (real deploy) = 22 passed, 0 failed
```

Adversarial review (fund-safety, accounting, simplicity): **0 confirmed findings** — partner can only ever take the
capped fees, never principal; net always reaches the user; per-block AUM blending verified correct.

## Layout
```
contracts/   collectors + FeeMath + interface
test/        unit/ + fluidlite/ (live) + ultrayield/ (real deploy)
docs/        ADR, Architecture, Implementation-plan
lib/         forge-std, openzeppelin-contracts(-upgradeable), ERC-7540-Reference, ultrayield-src (test-only)
```
