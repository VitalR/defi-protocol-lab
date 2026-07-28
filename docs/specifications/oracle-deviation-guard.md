# Oracle Deviation Guard

## Purpose

`OracleDeviationGuard` is a guarded primary-price oracle. It returns the price
reported by a configured primary oracle only when that price is sufficiently
close to an independent reference oracle.

The two sources have intentionally different roles:

- **Primary oracle:** the authoritative source whose price is returned.
- **Reference oracle:** a validation source used only as a circuit breaker.

The guard is not a fallback oracle, median oracle, or price aggregator. It does
not average the two prices and does not choose the lower or higher value.

## High-level flow

1. Read `(primaryPrice, primaryUpdatedAt)` from the primary oracle.
2. Read `(referencePrice, referenceUpdatedAt)` from the reference oracle.
3. Reject a zero reference price.
4. Calculate the absolute deviation relative to the reference price.
5. Revert when the deviation exceeds the configured limit.
6. Otherwise, return the primary price and the older observation timestamp.

Conceptually:

```text
primary oracle ── price to return ──┐
                                    ├── deviation check ── guarded primary price
reference oracle ─ validation only──┘
```

## Pair compatibility

Both underlying oracles must describe the same ordered price pair:

```text
primary.baseIdentifier()  == reference.baseIdentifier()
primary.quoteIdentifier() == reference.quoteIdentifier()
```

For example, `ETH/USD` is compatible with `ETH/USD`, but not with:

- `WBTC/USD`, because the base asset differs;
- `ETH/EUR`, because the quote asset differs;
- `USD/ETH`, because an inverse pair is economically different.

Compatibility is checked in the constructor. The guard exposes the primary
oracle's `baseIdentifier()` and `quoteIdentifier()` so it remains composable as
an `IPriceOracle`.

Matching identifiers do not prove that two sources use the same units. Every
`IPriceOracle` implementation must also satisfy the interface convention that
its price is normalized to WAD (`1e18`) precision.

## Deviation formula

Let:

- \(P\) be the primary price;
- \(R\) be the reference price;
- \(B = 10{,}000\), the basis-points denominator.

The guard calculates:

\[
\text{deviationBps}
=
\left\lceil
\frac{|P-R|\times B}{R}
\right\rceil
\]

The Solidity implementation uses full-precision `Math.mulDiv`:

```solidity
uint256 difference =
    primaryPrice > referencePrice
        ? primaryPrice - referencePrice
        : referencePrice - primaryPrice;

uint256 deviationBps = Math.mulDiv(
    difference,
    BPS_DENOMINATOR,
    referencePrice,
    Math.Rounding.Ceil
);
```

### Why the reference price is the denominator

The reference oracle is the validation benchmark, so the question is:

> By what percentage does the primary price differ from the reference price?

This makes the calculation intentionally asymmetric.

Example:

```text
P = 2,000
R = 1,900
deviation = ceil(100 / 1,900 × 10,000) = 527 bps
```

Reversing the sources produces:

```text
P = 1,900
R = 2,000
deviation = ceil(100 / 2,000 × 10,000) = 500 bps
```

The absolute price difference is identical, but the percentage benchmark is
different. This is expected and reinforces that primary and reference sources
are not interchangeable.

### Why deviation rounds upward

Deviation is a safety check. Rounding down could classify a value slightly
above the configured limit as acceptable. Ceiling rounding makes the guard
conservative:

```text
exact deviation = 2000.01 bps
rounded down     = 2000 bps → incorrectly accepted
rounded up       = 2001 bps → rejected
```

## Threshold semantics

The instance-specific limit is `maxDeviationBps`.

```solidity
if (deviationBps > maxDeviationBps) {
    revert PriceDeviationExceeded(...);
}
```

Therefore:

- deviation below the limit succeeds;
- deviation exactly equal to the limit succeeds;
- deviation above the limit reverts.

`MAX_DEVIATION_BPS = 5_000` is a constructor configuration ceiling, not the
active threshold of every deployment. For example, a guard deployed with
`maxDeviationBps = 2_000` permits at most 20% calculated deviation even though
the contract allows deployments to configure up to 50%.

The 50% ceiling is a protocol policy choice. A production deployment will
usually need a much tighter threshold chosen for the asset, source behavior,
market volatility, expected update cadence, and protocol risk tolerance.

## Why the guard always returns the primary price

When validation succeeds, the guard returns:

```solidity
return (primaryPrice, Math.min(primaryUpdatedAt, referenceUpdatedAt));
```

The deviation calculation is only an acceptance check:

```text
within threshold → return primaryPrice
above threshold  → revert
```

For example, if the primary price is `1,900`, the reference price is `2,000`,
and the deviation is permitted, the returned price is `1,900`.

Returning `min(primaryPrice, referencePrice)` for collateral or
`max(primaryPrice, referencePrice)` for debt could be a valid lending-specific
risk rule, but that policy belongs in the protocol consumer or risk engine.
Keeping it out of this guard makes the oracle reusable and gives it one clear
responsibility.

## Timestamp policy

The returned timestamp is:

\[
\min(\text{primaryUpdatedAt},\ \text{referenceUpdatedAt})
\]

It represents the older observation used to validate the result. Returning the
newer timestamp would overstate the freshness of the combined decision.

The guard itself does not implement a staleness window. Each underlying oracle
adapter remains responsible for validating its own timestamp, freshness,
round completeness, and source-specific rules before returning a price.

## Constructor validation

Deployment rejects:

- a zero primary oracle address;
- a zero reference oracle address;
- using the same address for both roles;
- `maxDeviationBps == 0`;
- a limit above `MAX_DEVIATION_BPS`;
- different base identifiers;
- different quote identifiers.

Requiring distinct addresses prevents the most obvious configuration in which
the primary oracle validates itself. It does not guarantee economic
independence: two different adapters may still depend on the same feed,
liquidity pool, reporter set, or upstream data provider.

## Runtime validation

The guard explicitly rejects `referencePrice == 0` before division. This:

- prevents a zero-denominator failure;
- returns a domain-specific `InvalidReferencePrice` error;
- protects the guard if a future or non-compliant `IPriceOracle` implementation
  fails to enforce positive prices.

The current `PushOracleAdapter` already rejects non-positive feed answers.
Testing the guard's defensive branch therefore requires a deliberately
non-compliant or configurable `IPriceOracle` mock that returns zero.

The primary adapter is also expected to enforce its own price validity. With
the current maximum deviation ceiling, a zero primary price against a positive
reference would exceed the allowed deviation and revert, but adapters should
not rely on the guard as their primary input validator.

## Errors

| Error | Meaning |
| --- | --- |
| `ZeroPrimaryOracle()` | Primary oracle address is zero. |
| `ZeroReferenceOracle()` | Reference oracle address is zero. |
| `SameOracle()` | Both roles use the same oracle address. |
| `InvalidMaxDeviationBps(value)` | Threshold is zero or above the permitted ceiling. |
| `OracleBaseMismatch(primaryBase, referenceBase)` | Base identifiers differ. |
| `OracleQuoteMismatch(primaryQuote, referenceQuote)` | Quote identifiers differ. |
| `InvalidReferencePrice()` | Reference oracle returned zero. |
| `PriceDeviationExceeded(P, R, actual, maximum)` | Calculated deviation is above the configured limit. |

## Core invariants

For every successful `latestPrice()` call:

1. The returned price equals the primary oracle price.
2. The calculated deviation is less than or equal to `maxDeviationBps`.
3. The reference price is non-zero.
4. The returned timestamp equals the older underlying timestamp.
5. Both sources describe the same ordered base/quote pair.
6. `baseIdentifier()` and `quoteIdentifier()` equal the primary oracle
   identifiers.

The pair identifiers and threshold are immutable after deployment.

## Recommended test matrix

### Deployment

- stores both oracle addresses and the configured threshold;
- propagates base and quote identifiers;
- rejects each zero address;
- rejects the same oracle address;
- rejects zero threshold;
- accepts the maximum configuration ceiling;
- rejects one unit above the ceiling;
- rejects a base mismatch;
- rejects a quote mismatch.

### Price behavior

- equal prices succeed with zero deviation;
- deviation below the active limit succeeds;
- deviation exactly at the limit succeeds;
- deviation one basis point above the limit reverts;
- primary above reference is calculated correctly;
- primary below reference is calculated correctly;
- fractional deviation rounds upward;
- returned price is always the primary price;
- returned timestamp is the older timestamp;
- zero reference price reverts through a configurable mock;
- large values do not overflow in the deviation calculation.

Failures produced by the underlying adapters should propagate. Their detailed
stale-price, invalid-round, future-timestamp, and invalid-answer cases belong in
the adapter-specific test suites and do not need to be duplicated exhaustively
here.

## Trust and security assumptions

The guard reduces risk from one source diverging from another, but it cannot
prove that either price is correct.

Important limitations:

- **Correlated sources:** separate contract addresses may depend on the same
  upstream provider or reporter set.
- **Shared liquidity:** both sources may derive prices from the same or closely
  related pools.
- **Dual manipulation:** an attacker who can influence both sources may keep
  their deviation within the limit.
- **Reference manipulation:** because the reference price is the denominator,
  manipulating it changes both the benchmark and the calculated percentage.
- **Stale-but-valid data:** unsuitable adapter staleness limits can allow old
  values even though the guard itself behaves correctly.
- **Threshold selection:** a limit that is too wide permits dangerous
  divergence; one that is too narrow may halt the protocol during normal
  volatility.
- **Market dislocation:** two healthy sources can legitimately diverge during
  rapid moves, low liquidity, or different update schedules.
- **Denomination mismatch:** matching identifiers alone cannot detect a broken
  adapter that returns incorrectly scaled values.

This guard is a circuit breaker, not a complete oracle-security solution.

## Integration guidance

A typical composition is:

```text
PushOracleAdapter (primary)
             \
              OracleDeviationGuard → protocol consumer
             /
TWAP adapter (reference)
```

Before deployment:

1. Verify that both adapters return WAD-normalized prices.
2. Verify identical base/quote ordering.
3. Confirm that the sources are economically independent where practical.
4. Select adapter staleness limits consistent with their update models.
5. Select `maxDeviationBps` using asset-specific risk analysis.
6. Define protocol behavior when the guard reverts: pause, reject the action,
   or use a separately designed fallback mechanism.
7. Monitor both raw prices, deviation, observation timestamps, and revert rate.

A fallback must be explicit. Silently returning the reference price after the
primary source fails would change the contract's trust model and should be
implemented and reviewed as a separate policy.

## Mental model

> `OracleDeviationGuard` is a validated-primary oracle: the primary source
> determines the output, while the reference source determines whether that
> output is acceptable.

