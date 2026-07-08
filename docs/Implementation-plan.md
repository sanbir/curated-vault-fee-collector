# Implementation Plan — Curated Vault Fee Collector

## Scope

- Solidity 0.8.28 and Foundry.
- UltraYield support is V2-only through `UltraYieldV2FeeCollector` and `IUltraVaultV2`.
- The target V2 vault is constructor-injected. No implementation address is hardcoded.
- Fluid Lite remains supported through `FluidLiteFeeCollector`.
- Partner fees are deposit, withdrawal, and per-block AUM fees.

## Layout

```text
contracts/
  libraries/FeeMath.sol
  interfaces/IUltraVaultV2.sol
  CuratedFeeCollectorBase.sol
  FluidLiteFeeCollector.sol
  UltraYieldV2FeeCollector.sol
test/
  BaseFork.t.sol
  unit/FeeMath.t.sol
  fluidlite/FluidLiteFeeCollector.t.sol
  ultrayield_v2/UltraYieldV2FeeCollector.t.sol
  ultrayield_v2/V2ComplianceStuckFunds.t.sol
  ultrayield_v2/V2UpgradeAuthority.t.sol
```

## V2 admission and exit policy

1. The vault administrator allowlists the deployed collector.
2. At deposit, the collector checks `isAllowed` for both `msg.sender` and the position beneficiary.
3. The collector deposits into the constructor-supplied V2 vault and custodies its shares.
4. Allowlist removal prevents future deposits but does not block async or instant exits.

## Verification

- Unit and fuzz tests for fee arithmetic.
- Mainnet-fork tests against deployed protocol bytecode without mocked calls.
- V2 tests cover KYC combinations, vault-admin onboarding, deposit, async and instant exits, fee stacking,
  pooled users, partial fulfillment, access control, and exit after de-listing.
- Definition of done: `forge test` and `git diff --check` pass.
