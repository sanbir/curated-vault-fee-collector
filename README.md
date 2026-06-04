# Curated Vault Fee Collector

A P2P fee layer that sits on top of **curated UltraYield and Fluid Lite vaults** and charges end users a
**deposit fee**, a **withdrawal fee**, and a **performance fee against each user's *individual* high-water
mark (HWM)** — not socialized across the pool.

See [`docs/ADR.md`](docs/ADR.md), [`docs/Architecture.md`](docs/Architecture.md), and
[`docs/Implementation-plan.md`](docs/Implementation-plan.md) for the design.

## Why a separate layer

The underlying vaults issue **fungible** shares and track at most a single **global** HWM. Per-user HWM is
impossible on a fungible share (it leaks on transfer). This layer custodies the underlying shares and
credits each user a **non-transferable** position carrying its own HWM. One collector wraps one vault.

## Contracts (`contracts/`)

| Contract | Underlying | Exit model |
|---|---|---|
| `FluidLiteFeeCollector` | synchronous ERC-4626 (fLiteUSD, iETHv2) | one-tx `redeem` |
| `UltraYieldFeeCollector` | ERC-7540 async (UltraYield `UltraVault`) | `requestRedeem` → operator fulfill → `claim` |
| `CuratedFeeCollectorBase` | — | shared deposit / HWM-crystallization / fees / admin |
| `libraries/HwmFeeMath` | — | pure deposit/withdrawal/HWM-performance math |

Key properties: per-user HWM is a **price** (`convertToAssets(SHARE_UNIT)`), ratchets up only; performance
fee is **skimmed in shares** into a fee pool; deposit/withdrawal fees are taken **in asset**; fee caps are
enforced on the **new** value; positions are **non-transferable** and **custody-only**; `Ownable2Step` +
`Pausable` + `ReentrancyGuard`.

## Tests — mainnet fork, no mocks

35 tests, **no `vm.mockCall`** anywhere:

- `test/unit/HwmFeeMath.t.sol` — 14 deterministic + fuzz tests of every HWM branch, incl. non-socialization.
- `test/fluidlite/FluidLiteFeeCollector.t.sol` — 10 tests against the **live `fLiteUSD`** vault
  (`0x273DA948…9012`); real USDC, real auto-accrued yield (via `vm.warp`), proves per-user non-socialization
  on a live vault, deposit/withdraw/perf fees, top-up, partial redeem, caps, pause, custody-only.
- `test/fluidlite/FeeFreeUnderlying.t.sol` — 3 tests against the **live fee-free `fUSDC`** ERC-4626 vault
  (`0x9Fb7b447…1B33`), representing the **new fee-free curated vault**. Proves the underlying takes nothing on
  deposit/withdraw/yield (grown redeem == accounted NAV to the wei) and that the collector is the **only** fee
  layer (value conservation: principal + yield == user + collector fees, no leak).
- `test/ultrayield/UltraYieldFeeCollector.t.sol` — 8 tests against a **self-deployed real UltraYield vault**
  (actual `UltraVault`/`UltraVaultOracle`/`UltraVaultRateProvider` compiled & deployed on the fork, configured
  **fee-free**). Drives the NAV oracle **up and down** to exercise the HWM gate across a real drawdown, the full
  async request→fulfill→claim lifecycle, non-socialization across a drawdown, two-step fee collection, plus
  fee-free-underlying assertions (zero-fee full-gain passthrough).

### Run

```bash
# Uses a public archive RPC by default; set your own for speed/reliability:
export MAINNET_RPC_URL=https://your-archive-rpc
forge test -vv
```

Fork is pinned to a recent block (`FORK_BLOCK` in `test/BaseFork.t.sol`). The default fallback RPC is an
archive-capable public endpoint so the suite runs out-of-the-box.

### Latest result

```
14 unit + 10 fLiteUSD (live) + 3 fee-free fUSDC (live) + 8 UltraYield (real deploy) = 35 passed, 0 failed
```

**Fee model is configured fee-free at the underlying** (per the deployment decision): the curated vaults
P2P/Edge deploy charge no protocol fee, so the collector is the sole fee layer. This is proven directly —
fee-free `fUSDC` grown redeem returns the accounted NAV to the wei, and value conservation holds.

Representative live numbers: fLiteUSD real accrual 1.0226→1.0629 over 180d → 779 USDC perf fee collected;
non-socialization on the live vault (alice 1,038 vs bob 505 USDC same deposit, different entry); UltraYield
HWM gate charges only the 1.2→1.3 excess after a real 1.2→1.0→1.1 drawdown.

## Layout
```
contracts/   collectors + HwmFeeMath + interfaces
test/        unit/ + fluidlite/ (live) + ultrayield/ (real deploy)
docs/        ADR, Architecture, Implementation-plan
lib/         forge-std, openzeppelin-contracts(-upgradeable), ERC-7540-Reference, ultrayield-src (test-only)
```
`lib/ultrayield-src` is the real UltraYield protocol source, vendored so the async tests can deploy a real
instance on the fork (it is **not** a mock).
