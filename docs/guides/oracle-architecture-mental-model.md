# Oracle Architecture Mental Model

## Why this module exists

The goal is to understand how a DeFi protocol turns an external price
observation into a value that is safe to use in collateral, debt, health-factor,
borrowing, and liquidation calculations.

The system separates four different responsibilities:

```text
External feed
    ↓ raw answer with feed-specific decimals
PushOracleAdapter
    ↓ validated USD price in WAD
AssetOracleRouter
    ↓ selects the configuration for an asset
Valuation math
    ↓ USD value in WAD, rounded according to financial risk
Lending protocol
    ↓ collateral, debt, health factor, liquidation decisions
```

This separation is the main architectural lesson.

## System invariant: the quote currency is always USD

For this lab, every accepted oracle reports:

```text
BASE / USD
```

Examples:

```text
ETH/USD
WBTC/USD
USDC/USD
```

Therefore, the router does not need to support arbitrary quote currencies. It
should be a USD-denominated router with one fixed invariant:

> Every configured adapter must return a USD price normalized to 18 decimals.

The earlier test-plan item:

```text
wrong oracle quote → pair mismatch
```

is not an important recurring business scenario once the design fixes the quote
to USD. There are two reasonable implementations:

1. Validate `quoteIdentifier == USD` once when an adapter is configured.
2. Make the USD-only assumption part of the oracle interface and omit runtime
   quote metadata from the router.

For a learning lab, option 1 is useful as a single boundary/invariant test. It
demonstrates that configuration is untrusted input. It does **not** justify a
large family of quote-currency tests.

The more relevant configuration mistake is:

```text
WETH asset address → WBTC/USD adapter
```

Both are USD feeds and both may be fresh and positive, but the price is for the
wrong base asset. Preventing or clearly governing this asset-to-adapter binding
is one of the router's real responsibilities.

## Contract responsibilities

### `PushOracleAdapter`

The adapter translates one external push feed into the protocol's internal price
format.

It should:

- read the latest feed observation;
- reject invalid or incomplete rounds;
- reject zero or negative prices;
- reject missing, future, or stale timestamps;
- normalize the feed's decimals to 18-decimal WAD;
- expose the timestamp together with the price;
- identify, or otherwise guarantee, the base asset and USD quote.

It should not:

- calculate a user's collateral value;
- know whether a price is being used for collateral or debt;
- decide which adapter belongs to an ERC-20;
- calculate health factors or liquidation amounts.

Mental model:

> The adapter answers: “Is this observation valid, and what is the normalized
> USD price?”

### `AssetOracleRouter`

The router is a governed mapping between protocol assets and their oracle
configuration.

Typical configuration:

```solidity
struct OracleConfig {
    IPriceOracle oracle;
    uint8 tokenDecimals;
    bool enabled;
}
```

Conceptually:

```text
WETH address → ETH/USD adapter, 18 token decimals, enabled
WBTC address → BTC/USD adapter, 8 token decimals, enabled
USDC address → USDC/USD adapter, 6 token decimals, enabled
```

It should:

- select the correct adapter for an asset address;
- store the asset's token decimals;
- reject unconfigured and disabled assets;
- permit only authorized configuration changes;
- calculate comparable USD WAD values;
- use conservative rounding based on the financial role;
- preserve the adapter's observation timestamp.

It should not:

- reimplement feed-round validation;
- know Chainlink-specific feed fields;
- silently substitute another feed when one fails;
- use token symbols as authoritative identity;
- calculate the complete account health factor.

Mental model:

> The router answers: “Which validated USD price and decimal configuration
> applies to this asset, and how should this amount be valued?”

### Valuation math

For a token amount with `tokenDecimals` and a price already normalized to WAD:

```text
valueWad = amount × priceWad / 10^tokenDecimals
```

Example:

```text
amount        = 2e18       // 2 WETH
priceWad      = 2_000e18   // $2,000 per WETH
tokenDecimals = 18
valueWad      = 4_000e18   // $4,000
```

For USDC:

```text
amount        = 1_500e6    // 1,500 USDC
priceWad      = 1e18       // $1
tokenDecimals = 6
valueWad      = 1_500e18   // $1,500
```

The input amount uses token decimals. The adapter's raw answer uses feed
decimals. The adapter output and final value both use 18-decimal WAD. Keeping
these units explicit prevents most oracle arithmetic mistakes.

## Why `ValueType` exists

`ValueType` does not mean that collateral and debt use different market prices.
They normally use the same validated price. It expresses how rounding risk must
be assigned:

```solidity
enum ValueType {
    Undefined,
    Collateral,
    Debt
}
```

Safety policy:

```text
Collateral → round down → do not over-credit the borrower
Debt       → round up   → do not understate what the borrower owes
```

If the division is exact, both results are equal. Their difference only appears
when there is a remainder.

Example:

```text
exact mathematical result = 1.000...001 smallest value unit

collateral result = 1
debt result       = 2
```

This asymmetry becomes important when values feed into:

- maximum borrow calculations;
- health factors;
- withdrawal eligibility;
- liquidation eligibility;
- liquidation repayment and collateral seizure.

Safer protocol-facing APIs are:

```solidity
collateralValueOf(asset, amount);
debtValueOf(asset, amount);
```

They prevent a higher-level lending contract from accidentally passing the
wrong enum member. A generic `valueOf(asset, amount, valueType)` remains useful
internally or for explicit low-level use.

## Why the router matters in a real protocol

Without a router, each lending-market function might independently:

- select a feed;
- read token decimals;
- normalize the price;
- select rounding;
- handle paused assets;
- interpret oracle failures.

That duplicates security-sensitive policy and makes inconsistent behaviour more
likely.

With a router, higher-level code can operate on one internal unit:

```text
USD WAD
```

For example:

```text
adjusted collateral =
    Σ(collateralValueWad × liquidationThreshold)

total debt =
    Σ(debtValueWad)

health factor =
    adjusted collateral / total debt
```

The router is therefore infrastructure for the next lending milestone. By
itself, it is intentionally small; its architectural value becomes clearer when
several assets participate in one account-level risk calculation.

## Important failure modes

### Wrong asset-to-feed binding

```text
WETH → WBTC/USD
```

The observation can be technically valid but economically wrong. This is a
configuration/governance failure, not a feed-data failure.

### Stale but otherwise valid price

The price may be positive and correctly scaled but too old for a safe borrowing
or liquidation decision. The adapter must fail closed.

### Decimal confusion

Typical mistakes:

- providing `2000e18` to a feed with 8 decimals;
- interpreting `2000` as 2,000 tokens when the token has 18 decimals;
- expecting the router output to use the token's decimals instead of WAD.

### Unsafe rounding

Rounding collateral up or debt down transfers rounding advantage to the
borrower and can accumulate across positions and operations.

### Unconfigured versus disabled assets

These states should be distinguishable:

```text
unconfigured → never accepted by the protocol
disabled     → configured previously, but intentionally unavailable now
enabled      → configured and usable
```

An asset must not become enabled before it has a valid oracle configuration.

### Oracle replacement risk

Replacing an adapter is a high-impact governance action. A production design may
use a timelock for normal changes and a faster guardian action for disabling a
dangerous asset.

## Testing strategy: value over coverage

Coverage is evidence that code was executed. It is not the learning objective,
and 100% alone does not prove that the right properties were tested.

For this curriculum, tests should be divided into three groups.

### 1. Tests worth writing manually

These teach or verify the core security model:

- feed decimals are normalized correctly;
- token decimals are interpreted correctly;
- collateral rounds down and debt rounds up;
- stale, invalid, and incomplete observations fail closed;
- an asset routes to the intended adapter;
- unconfigured and disabled assets cannot be valued;
- unauthorized configuration changes revert;
- configuration of the wrong base asset is rejected or otherwise prevented;
- replacing one asset's adapter does not affect another asset.

These tests correspond to real losses, broken accounting, or governance risks.

### 2. Tests that may be generated or kept minimal

These are useful for regression confidence but usually add little new learning
after the pattern is understood:

- every repeated zero-address branch;
- identical wrapper tests whose only difference is the called function;
- repeated event-field assertions;
- every getter returning exactly what a setter stored;
- the same access-control rejection for many equivalent functions;
- exhaustive manual cases created only to move coverage from 98% to 100%.

They can be generated, adapted from a template, or added only when a coverage
gap reveals an untested meaningful branch.

### 3. Tests that become more valuable later

When the router is integrated into lending logic, property-based tests are more
valuable than additional isolated branch tests:

- increasing an asset amount must not decrease its USD value;
- debt valuation must never be lower than floor valuation;
- total account debt must equal or exceed the sum of individually floored debts;
- a lower collateral price must not improve health factor;
- a higher debt price must not improve health factor;
- a disabled oracle must block risk-increasing operations;
- no decimal combination within supported bounds should overflow or silently
  change units.

These properties connect oracle behaviour to protocol solvency.

## Practical completion rule for this lab

Do not spend additional time manually manufacturing tests merely to preserve a
100% number if all meaningful branches and properties are already covered.

The oracle router milestone is complete when:

- its unit conventions are documented;
- USD is an explicit system invariant;
- asset-to-adapter routing is controlled;
- lifecycle states are correct;
- collateral/debt rounding is demonstrated with one inexact example;
- critical adapter failures propagate;
- the full repository test suite passes;
- coverage is high enough to reveal accidental gaps, not treated as the goal.

A reasonable policy for future milestones:

```text
First:  test economic invariants and dangerous transitions.
Second: test integration boundaries and adversarial inputs.
Third:  inspect coverage for missed logic.
Last:   add small regression tests only when they provide real confidence.
```

## Interview mental model

### Why normalize all prices to WAD?

It gives downstream protocol code one comparable unit, regardless of feed or
token decimals. This reduces duplicated conversions and unit mistakes.

### Why return `updatedAt`?

The adapter validates freshness, but consumers may also need the observation
time for monitoring, composed-oracle logic, or stricter operation-specific
policies.

### Why separate the adapter from the router?

The adapter validates and normalizes one feed technology. The router applies
protocol configuration and selects the adapter for an asset. This allows feeds
to change without rewriting account-level risk logic.

### Why can a fresh positive price still be unsafe?

It may belong to the wrong asset, use the wrong unit, come from a compromised
source, diverge from other markets, or be inappropriate for the asset's current
liquidity.

### Why round collateral down and debt up?

Protocol accounting should not overstate protection or understate obligations.
Conservative rounding assigns small numerical uncertainty away from the
borrower and toward protocol solvency.

### Is 100% coverage enough for an oracle module?

No. Coverage reports execution, not correctness. Important evidence also
includes explicit unit conventions, adversarial feed tests, configuration
controls, rounding properties, integration tests, fuzzing/invariants, and
review of economic assumptions.

## What this milestone intentionally does not solve

The current router does not yet provide:

- TWAP calculation;
- multiple-source aggregation;
- deviation or circuit-breaker checks;
- fallback-oracle policy;
- sequencer-uptime checks for L2;
- market-liquidity assessment;
- governance timelocks;
- health-factor or liquidation logic.

Those are later architectural topics. The present milestone provides the
trusted, normalized valuation boundary on which they can be built.

## Final checklist

- [ ] Every adapter returns a USD price in 18-decimal WAD.
- [ ] Raw feed decimals and token decimals are never confused.
- [ ] The asset-to-adapter binding is explicit and governed.
- [ ] Unconfigured assets cannot be enabled or valued.
- [ ] Disabled assets cannot be valued.
- [ ] Collateral uses floor rounding.
- [ ] Debt uses ceil rounding.
- [ ] Observation timestamps propagate.
- [ ] Unsafe oracle observations fail closed.
- [ ] Tests prioritize economic/security properties over a coverage number.
- [ ] Higher-level lending code consumes only normalized USD WAD values.

