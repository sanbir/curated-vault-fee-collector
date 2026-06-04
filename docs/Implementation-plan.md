# Implementation Plan — Curated Vault Fee Collector

> Companion to [ADR.md](./ADR.md) and [Architecture.md](./Architecture.md). Foundry project under `curated-vault-fee-collector/`.

---

## 0. Toolchain & layout

- **Foundry** (forge 1.5.x), Solidity **0.8.28**, EVM **cancun**, optimizer on (200 runs).
- Dependencies (vendored into `lib/`, copied from sibling projects — offline, no network):
  - `forge-std` (from `auto-rebalancer-safe-modules/lib`)
  - `openzeppelin-contracts` v5 (from `auto-rebalancer-safe-modules/lib`)
  - `openzeppelin-contracts-upgradeable` + `ERC-7540-Reference` (from `UltraYield/UltraYield-contracts/lib`) — **test-only**, to compile and self-deploy the real UltraYield vault on the fork.
- Layout:
  ```
  contracts/
    libraries/HwmFeeMath.sol
    interfaces/IUltraVault7540.sol      # ERC-7540 surface for the async collector
    CuratedFeeCollectorBase.sol         # shared deposit/HWM/fees/admin
    FluidLiteFeeCollector.sol
    UltraYieldFeeCollector.sol
  test/
    BaseFork.t.sol                 # fork scaffolding (mirrors example)
    unit/HwmFeeMath.t.sol          # pure-math unit tests (no fork)
    fluidlite/FluidLiteFeeCollector.t.sol   # live fLiteUSD fork
    ultrayield/UltraYieldFeeCollector.t.sol # real UltraYield deploy + async + HWM up/down fork
  docs/  (this folder)
  foundry.toml, remappings.txt, .env.example, .gitignore, README.md
  ```

Fork config mirrors the example: `vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", "https://eth-mainnet.public.blastapi.io"), FORK_BLOCK)` with a pinned recent `FORK_BLOCK` (= 25,230,000; > fLiteUSD deploy block 24.62M). The default fallback is an **archive-capable** public endpoint (pruned nodes can't serve historical state at a pinned block). `deal(token, who, amount, true)` for funding. No `vm.mockCall`.

---

## 1. Phases

### Phase A — Scaffold ✅ pre-req
foundry.toml, remappings, vendored libs, `.env.example`, `.gitignore`, README.

### Phase B — `HwmFeeMath` (pure library)
Functions (all `internal pure`, decimal-correct, rounding favors protocol):
- `bps(amount, rateBps)` → fee component.
- `splitDepositFee(assets, depositFeeBps)` → `(fee, net)`.
- `splitWithdrawFee(assets, withdrawFeeBps)` → `(fee, net)`.
- `accruedPerfAssets(shares, hwm, curRatio, shareUnit, perfBps)` → perf fee in **asset** units (0 if `curRatio <= hwm`).
- `assetsToShares(assets, curRatio, shareUnit)` → underlying shares (round **up** for fees).
- `newHwm(hwm, curRatio)` → `max(hwm, curRatio)`.

### Phase C — Collectors
Shared behavior (implemented per-contract, math via `HwmFeeMath`):
- `deposit(assets, receiver)`; per-user `Position{shares, hwm}`; `accruedFeeShares`; `collectFees()`.
- Owner: `setFees`, `setFeeRecipient`, `pause/unpause`; `Ownable2Step`; `ReentrancyGuard`; `Pausable`.
- Views: `positionOf`, `previewDeposit`, `pricePerShare`, `pendingPerfFee`, `totalManagedShares`.

**`FluidLiteFeeCollector`** (sync): `redeem(shares, receiver)` / `withdrawAll(receiver)` complete in one tx via `underlying.redeem`.

**`UltraYieldFeeCollector`** (async): `requestRedeem(shares)` (crystallize, move to per-user pending, `underlying.requestRedeem` as controller); `claim(receiver)` (after operator fulfillment, `underlying.redeem` → withdrawal fee → user); `cancelRequest()`; internal pending/claimable ledger. Constructor calls `underlying.setOperator(self, true)` is not needed (collector is controller==owner==self); confirm against source.

### Phase D — Tests (the expensive part)
**D1 `unit/HwmFeeMath.t.sol`** (no fork): every branch —
- perf fee 0 below/at HWM; correct above HWM; HWM ratchets up only.
- deposit/withdraw fee math incl. rounding direction.
- top-up: crystallize-then-raise (no forgiveness).
- partial withdraw preserves HWM (price).
- **non-socialization**: two positions, different `hwm`, same `curRatio` → different fees; user below their mark pays 0 while user above pays.
- boundaries: zero shares, zero rates, dust, large values; fuzz.

**D2 `fluidlite/FluidLiteFeeCollector.t.sol`** (live fLiteUSD fork, no mocks):
- deploy collector over live fLiteUSD; `deal` USDC.
- deposit → deposit fee to recipient; collector holds fLiteUSD shares; user position recorded.
- `vm.warp` ~180 days → fLiteUSD exchange price accrues (real) → `pricePerShare` rises.
- redeem → withdrawal fee + perf fee (skimmed shares) → user gets net; `feeRecipient` perf-fee value > 0.
- **two users, staggered entry** (user B deposits after warp at a higher ratio) → after more warp, each pays perf fee only on **their own** gain above **their own** HWM (B's fee ≪ A's per-share-equivalent) — proves non-socialization on a live vault.
- top-up after accrual; partial redeem preserves HWM; `collectFees()` pays `feeRecipient` in USDC.
- access control & caps revert paths; pause blocks deposits; non-transferability (no transfer fn).

**D3 `ultrayield/UltraYieldFeeCollector.t.sol`** (self-deployed real UltraYield fork, no mocks):
- `UltraYieldDeploy` harness deploys real `UltraVaultOracle`, `UltraVaultRateProvider`, `UltraVault` (UUPS), wires roles; base asset = real USDC (deal); test is oracle owner + operator.
- deposit via collector; set oracle price **up** → request/fulfill/claim → perf fee charged on gain above HWM; HWM ratchets.
- set oracle price **down** (real drawdown) then partial recovery **below** prior HWM → request/claim → **no perf fee** (gate works); then price **above** old HWM → perf fee resumes only on the new excess.
- two users across the drawdown → non-socialization with a real falling NAV.
- async specifics: `requestRedeem` locks fee; operator `fulfillRedeem`; `claim` pays net; `cancelRequest` returns shares.

### Phase E — Green run
`forge build`; `forge test -vvv` (fork). Iterate until all pass. Capture gas report. Save logs under `test_logs/`.

---

## 2. Test matrix (what proves the requirements)

| Requirement | Unit (HwmFeeMath) | fLiteUSD live fork | UltraYield self-deploy fork |
|---|---|---|---|
| Deposit fee | ✅ | ✅ | ✅ |
| Withdrawal fee | ✅ | ✅ | ✅ |
| Perf fee above personal HWM | ✅ | ✅ (real accrual) | ✅ |
| **No fee below personal HWM (drawdown)** | ✅ | — (price monotonic) | ✅ (real oracle down) |
| HWM ratchets up only | ✅ | ✅ | ✅ |
| **Per-user, not socialized** | ✅ | ✅ (staggered entry) | ✅ (across drawdown) |
| Top-up crystallize-then-raise | ✅ | ✅ | ✅ |
| Partial-withdraw HWM preservation | ✅ | ✅ | ✅ |
| Custody-only / non-transferable | — | ✅ | ✅ |
| Caps enforced on new value | ✅ | ✅ | ✅ |
| Async request→fulfill→claim | — | — | ✅ |
| Fee collection to recipient | — | ✅ | ✅ |

---

## 3. Risks & mitigations
- **UltraYield self-deploy integration** (4 libs, UUPS init, roles) is the main risk → isolate in a dedicated `UltraYieldDeploy` harness; if a deploy detail blocks, the sync+unit suites still fully prove the fee logic and the async contract still compiles and is covered against the real interface.
- **stETH `deal` quirks** → prefer USDC underlyings for both fork suites (fLiteUSD is USDC; self-deployed UltraVault uses USDC).
- **Public RPC flakiness** → pinned block + `envOr` fallback; `MAINNET_RPC_URL` recommended for speed.

---

## 4. Definition of done
- `forge build` clean; `forge test` all green on fork.
- Every row of the test matrix has a passing test.
- No `vm.mockCall` anywhere (grep clean).
- Gas report captured; README documents how to run.
