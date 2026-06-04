# Implementation Plan — Curated Vault Fee Collector

> Companion to [ADR.md](./ADR.md) and [Architecture.md](./Architecture.md). Foundry project under `curated-vault-fee-collector/`.

## 0. Toolchain & layout

- Foundry (forge 1.5.x), Solidity 0.8.28, EVM cancun, optimizer 200.
- Deps vendored in `lib/`: `forge-std`, `openzeppelin-contracts`, `openzeppelin-contracts-upgradeable` + `ERC-7540-Reference` + `ultrayield-src` (test-only, to self-deploy real UltraYield on the fork).
- Layout:
  ```
  contracts/
    libraries/FeeMath.sol             # deposit/withdrawal % + per-block AUM (pure)
    interfaces/IUltraVault7540.sol    # requestRedeem / redeem / maxRedeem
    CuratedFeeCollectorBase.sol       # deposit, fee settlement, admin, partner auth
    FluidLiteFeeCollector.sol         # synchronous exit
    UltraYieldFeeCollector.sol        # ERC-7540 async exit
  test/
    BaseFork.t.sol
    unit/FeeMath.t.sol
    fluidlite/FluidLiteFeeCollector.t.sol     # live fLiteUSD fork
    ultrayield/UltraYieldFeeCollector.t.sol   # self-deployed real UltraYield fork
  ```
- Fork: `vm.createSelectFork(envOr("MAINNET_RPC_URL", <archive fallback>), FORK_BLOCK)` at a pinned recent block; `deal(...,true)` funding; **no `vm.mockCall`**.

## 1. Scope (bare minimum)

The collector charges exactly three partner fees and nothing else:
- **deposit fee** (% of deposit) — at deposit, by the user.
- **withdrawal fee** (% of redeemed assets) — at withdrawal.
- **AUM fee** (per-block fraction of redeemed assets) — at withdrawal, measured by blocks under management.

Both the **user** and the **partner** can withdraw any amount at any time; net assets always go to the user, fees to the partner. No performance/HWM fee (handled by the underlying vaults' native fees). No fee-share pool (fees paid straight to the partner).

## 2. Phases

- **A — Contracts**: `FeeMath` → `CuratedFeeCollectorBase` (deposit + `_chargeAndPay` + admin + partner auth + weighted `lastBlock`) → `FluidLiteFeeCollector` (sync) → `UltraYieldFeeCollector` (async request/claim, user + partner variants).
- **B — Tests (mainnet fork, no mocks)**:
  - `unit/FeeMath.t.sol`: bps fee rounding/zero/exact; AUM value, scales-with-blocks, zero cases; fuzz (AUM monotonic in blocks, fee ≤ amount).
  - `fluidlite/…` (live fLiteUSD): deposit fee→partner; withdrawal+AUM→partner with net→user; partner `withdrawAllFor` (net to user); AUM scales with blocks (`vm.roll`); no-AUM same block; top-up blends `lastBlock`; partial withdraw preserves `lastBlock`; caps/access/pause/custody-only. (Expected fees computed from `previewRedeem`, which accounts for fLiteUSD's own native withdrawal fee.)
  - `ultrayield/…` (self-deployed real UltraYield): deposit fee; async request→fulfill(operator)→claim with withdrawal+AUM at claim; partner `requestRedeemAllFor`/`claimFor` (net to user); `onlyPartner` guard.
- **C — Review**: adversarial review (fund-safety, accounting, simplicity) → fix confirmed findings (result: 0 confirmed).
- **D — Docs**: ADR / Architecture / Implementation-plan / README.

## 3. Test matrix

| Requirement | unit | fLiteUSD (live) | UltraYield (real deploy) |
|---|---|---|---|
| Deposit fee → partner | ✅ | ✅ | ✅ |
| Withdrawal fee → partner | ✅ | ✅ | ✅ |
| AUM fee per block → partner | ✅ | ✅ | ✅ |
| AUM scales with blocks held | ✅ | ✅ | ✅ |
| Net assets → user (incl. partner-initiated) | — | ✅ | ✅ |
| Partner can withdraw for users | — | ✅ | ✅ |
| Top-up blends AUM start block | — | ✅ | — |
| Partial withdraw preserves start block | — | ✅ | — |
| Async request → fulfill → claim | — | — | ✅ |
| Caps / access / pause / custody-only | ✅ | ✅ | ✅ (onlyPartner) |

## 4. Definition of done
`forge build` clean; `forge test` green on fork; every matrix row covered; no `vm.mockCall`; review with 0 confirmed findings; docs updated.
