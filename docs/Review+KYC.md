# UltraYield V2 Integration and KYC Review

## Supported integration

Only UltraYield V2 is supported. `UltraYieldV2FeeCollector` receives a vault proxy in its constructor and calls
the minimal `IUltraVaultV2` surface. Neither the collector nor its interface identifies a specific implementation
address, so production can supply a different audited V2 `AllowlistUltraVault` deployment.

## KYC enforcement

UltraYield sees the collector as depositor, share receiver, share owner, and redemption controller. Consequently:

- the vault administrator must allowlist each collector deployment;
- the collector queries that same vault's `isAllowed` for the deposit funder and position beneficiary;
- both checks run before assets or deposit fees move;
- removing either address prevents subsequent deposits involving that address.

The collector deliberately does not check `isAllowed` during exits. A user removed after depositing can still
request and claim an async redemption or use instant redeem. This is exit-only de-listing, not a compliance freeze.

## Operational trust assumptions

- The selected vault implements the documented V2 and allowlist semantics.
- UltraYield administrators maintain the allowlist and onboard the collector.
- Async settlement depends on an authorized UltraYield operator and funds-holder liquidity/allowance.
- Instant settlement depends on exitpoint liquidity/allowance.
- The selected vault is upgradeable, so implementation upgrades must be monitored and re-tested.
- All collector users share one pooled UltraYield controller request; claims are first-come-first-served against
  available fulfilled shares, while each user's collector balance remains separately accounted.

## Fork verification

The V2 fork suite verifies:

- an unlisted collector cannot deposit;
- unlisted funders and beneficiaries cannot deposit;
- distinct allowed funder and beneficiary addresses work;
- deposit, async, partial, multi-user, partner-driven, and instant flows charge the configured partner fees;
- both async and instant exits remain available after user allowlist removal;
- the collector works through the deployed proxy ABI without depending on a hardcoded implementation address.
