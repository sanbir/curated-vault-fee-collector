# Curated Vault Fee Collector

A partner-fee layer for UltraYield V2 async vaults and Fluid Lite synchronous ERC-4626 vaults. The underlying
vault keeps its native fees; the collector adds deposit, withdrawal, and per-block AUM fees paid directly to the
partner.

The collector custodies underlying vault shares and records a non-transferable internal position per user. Both
the user and partner can initiate exits, but principal always goes to the user.

## Contracts

| Contract | Underlying | Exit model |
|---|---|---|
| `UltraYieldV2FeeCollector` | UltraYield V2 allowlist vault | async request/fulfill/claim and instant redeem |
| `FluidLiteFeeCollector` | synchronous ERC-4626 | synchronous redeem |
| `CuratedFeeCollectorBase` | shared | deposit, fee settlement, positions, administration |
| `FeeMath` | shared | deposit, withdrawal, and per-block AUM arithmetic |

`UltraYieldV2FeeCollector` is address-agnostic: its constructor accepts the target vault proxy as `IERC4626` and
uses the minimal `IUltraVaultV2` interface. It does not hardcode an implementation or deployment address.

For V2 deposits, both the funder and internal-position beneficiary must pass the target vault's `isAllowed`
check. The collector itself must also be allowlisted by the vault administrator because it receives and custodies
the actual vault shares. Exit paths remain open after a user is removed from the allowlist.

## Tests

The V2 integration suite forks mainnet at a pinned recent block and exercises an existing V2 test deployment
without `vm.mockCall` or protocol redeployment. Coverage includes:

- vault-admin onboarding of the collector;
- funder and beneficiary KYC checks;
- deposit fee and real funds-holder transfer;
- async request, operator fulfillment, partial fulfillment, and claims;
- instant redemption and native-fee stacking;
- pooled multi-user accounting and partner-driven exits;
- successful async and instant exit after user allowlist removal.

```bash
export MAINNET_RPC_URL=https://your-mainnet-rpc
forge test -vv
```

Latest result: `47 passed, 0 failed`.

## Layout

```text
contracts/   V2/Fluid collectors, minimal interfaces, and FeeMath
test/        unit, Fluid Lite fork, and UltraYield V2 fork tests
docs/        architecture and operational decisions
lib/         Foundry, OpenZeppelin, ERC-7540, and UltraYield V2 test sources
```
