# Decimal Math Specification

## Purpose

`DecimalMath` provides small, explicit helpers for working with token amounts, oracle prices, ratios, and other fixed-point values that use different decimal representations.

Solidity stores integers and does not provide protocol-safe floating-point arithmetic. A value such as `1.5` is therefore represented as an integer together with an implied decimal scale. With 18 decimals, `1.5` is represented as `1.5e18`.

The library normalizes supported inputs to a common 18-decimal unit, called WAD, before values are compared or combined.

## Terminology

### Raw amount

The integer stored or accepted by a contract.

Examples:

| Human amount | Decimals | Raw amount |
| --- | ---: | ---: |
| 1 USDC-like token | 6 | `1e6` |
| 1 oracle-priced unit | 8 | `1e8` |
| 1 WETH-like token | 18 | `1e18` |

### WAD

WAD is the project-wide 18-decimal fixed-point representation:

```solidity
uint256 constant WAD = 1e18;
```

Examples:

| Human value | WAD representation |
| --- | ---: |
| 0.5 | `0.5e18` |
| 1 | `1e18` |
| 1.25 | `1.25e18` |
| 80% | `0.8e18` |

WAD is a convention, not a Solidity type. Callers must still know the semantic unit of a value, such as USD, ETH, a collateral ratio, or a health factor.

## Supported decimals

The initial implementation supports decimal values from 0 through 18 inclusive.

Inputs above 18 decimals revert with:

```solidity
UnsupportedDecimals(uint8 decimals)
```

This bound keeps the first implementation simple and covers the token and oracle formats used in the initial protocol modules. It may be generalized later if a concrete integration requires more precision.

## `scale`

```solidity
scale(amount, fromDecimals, toDecimals, rounding)
```

`scale` changes the decimal representation of an amount without intentionally changing its economic value.

### Equal decimals

When `fromDecimals == toDecimals`, the original raw amount is returned unchanged.

### Scaling up

When `fromDecimals < toDecimals`:

```text
result = amount * 10^(toDecimals - fromDecimals)
```

Scaling up is exact, so the rounding parameter has no effect.

Example:

```text
scale(3e6, 6, 18) = 3e18
```

Both values represent the human amount `3`.

### Scaling down

When `fromDecimals > toDecimals`:

```text
result = amount / 10^(fromDecimals - toDecimals)
```

Scaling down may discard lower-order digits. The supplied rounding mode determines how the remainder is handled.

Example:

```text
raw input = 1_234_567_890_123_456_789 with 18 decimals

Floor to 6 decimals = 1_234_567
Ceil to 6 decimals  = 1_234_568
```

The raw input must not be multiplied by another `1e18`; it already contains 18 decimal places.

## `valueInWad`

```solidity
valueInWad(amount, amountDecimals, price, priceDecimals, rounding)
```

`valueInWad` calculates the quote value of a token amount and returns that value with 18 decimals.

The price is interpreted as quote units per one whole token.

Conceptually:

```text
value = token amount * price per token
```

Implementation model:

```text
normalizedPrice = scale(price, priceDecimals, 18)

valueWad = amount * normalizedPrice / 10^amountDecimals
```

Example:

```text
amount = 2e18       // 2 WETH-like tokens
price  = 2_000e8    // 2,000 quote units, 8 decimals

valueInWad = 4_000e18
```

The result represents 4,000 quote units using 18 decimals.

The function only performs arithmetic normalization. It does not validate whether an oracle price is fresh, positive in its original signed representation, manipulation-resistant, or appropriate for the requested asset.

## `ratioWad`

```solidity
ratioWad(numerator, denominator, rounding)
```

`ratioWad` divides two values expressed in compatible units while preserving 18-decimal fractional precision:

```text
ratioWad = numerator * 1e18 / denominator
```

Example health factor:

```text
adjusted collateral = 3_200e18
debt                = 3_000e18

ratioWad            = 1.066666666666666666e18 (Floor)
```

The denominator must be nonzero. A zero denominator reverts with:

```solidity
ZeroDenominator()
```

The caller defines the semantic meaning of a zero-debt position separately. For example, a lending protocol may return `type(uint256).max` before calling `ratioWad` when debt is zero.

## Rounding policy

Rounding is an economic and security decision.

The default conservative guidance is:

- round user assets, collateral value, redeem output, and health factor down;
- round debt, fees, required payment, mint input, and withdrawal share cost up.

This is guidance rather than a universal rule. Each protocol operation must document who receives the rounding remainder and why.

For the same valid input:

```text
Floor result <= exact mathematical result <= Ceil result
```

When a single integer division is performed:

```text
Ceil result - Floor result <= 1
```

## Overflow behavior

Scaling up uses checked Solidity multiplication and reverts if the scaled result does not fit into `uint256`.

Multiplication followed by division uses OpenZeppelin `Math.mulDiv` so that a valid final `uint256` result is not lost merely because the intermediate 256-bit multiplication would overflow.

Overflow is not converted into saturation or a special maximum value.

## Non-goals

`DecimalMath` does not:

- fetch or validate oracle reports;
- infer token decimals;
- identify the economic unit of an input;
- support signed values;
- calculate interest or compounding;
- guarantee that two values passed to `ratioWad` use compatible units;
- replace operation-specific slippage or solvency checks.

## Minimum correctness properties

The implementation and tests must establish:

1. Scaling up by a supported decimal difference is exact.
2. Scaling down with Floor never exceeds the exact mathematical result.
3. Scaling down with Ceil is never below the exact mathematical result.
4. For one scaling-down division, Ceil and Floor differ by at most one raw output unit.
5. Equal-decimal scaling returns the original raw amount.
6. Unsupported decimal values revert with the expected custom error.
7. `valueInWad` returns correctly normalized 18-decimal quote values.
8. `ratioWad` preserves fractional precision and rejects a zero denominator.
9. Exact round trips preserve the original value when no precision is discarded.
10. Lossy Floor round trips cannot create value.
