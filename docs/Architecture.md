# Architecture — Curated Vault Fee Collector

## Components

```text
allowed funder ── assets ──► collector ── net deposit ──► underlying vault
                                  │                           │
                                  │ internal user position    │ vault shares
                                  │                           ▼
                                  └────── custodies shares ◄──┘

exit: underlying assets ──► collector ── partner fees ──► partner
                                  └────── net assets ────► user
```

| Contract | Responsibility |
|---|---|
| `UltraYieldV2FeeCollector` | V2 KYC admission, async and instant exits |
| `FluidLiteFeeCollector` | synchronous ERC-4626 exits |
| `CuratedFeeCollectorBase` | deposits, positions, fee settlement, owner/partner controls |
| `FeeMath` | percentage and per-block AUM arithmetic |

UltraYield support is V2-only. The V2 collector accepts the vault proxy in its constructor and contains no
deployment or implementation address constant.

## State and custody

Each collector instance supports multiple users:

```solidity
struct Position { uint256 shares; uint256 lastBlock; }
mapping(address => Position) internal s_positions;
```

The users do not receive transferable vault shares. The collector owns the actual shares and attributes them
through its internal ledger. UltraYield therefore sees one pooled share owner/controller: the collector.

## UltraYield V2 KYC

Before a V2 deposit moves tokens, the collector queries the selected vault's `isAllowed` for:

1. `msg.sender`, the source of funds; and
2. `_receiver`, the internal-position beneficiary.

The collector address must separately be allowlisted by the vault administrator because UltraYield mints the
actual shares to it. The check is intentionally deposit-only. Removing a user blocks new deposits but does not
block request, claim, or instant redeem, avoiding trapped positions.

## Exit flows

- Async: user or partner requests redemption; UltraYield's operator fulfills the pooled controller request;
  user or partner claims; collector fees go to the partner and net assets to the user.
- Instant: UltraYield burns collector-held shares and pays from its exitpoint; the collector charges partner
  withdrawal/AUM fees on the amount received and sends the remainder to the user.
- Fluid Lite: collector synchronously redeems underlying shares and performs the same fee split.

## Security properties

- Net principal always goes to the position owner, including partner-driven exits.
- Partner access is limited to the explicit `*For` paths and configured fees.
- Positions are non-transferable and pooled shares reconcile with active plus pending accounting.
- `nonReentrant` protects mutating entry points.
- Deposits fail closed if the V2 allowlist query fails.
- User de-listing cannot trap an existing V2 position.
