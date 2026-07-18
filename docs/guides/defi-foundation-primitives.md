# DeFi Foundation Primitives

This note summarizes the engineering mental models and review checklist established by the first `defi-protocol-lab` epic:

- decimal and fixed-point math;
- hostile ERC-20 integration;
- inbound and outbound balance-delta accounting;
- token callback reentrancy;
- exact allowance management around external spenders.

It is a cross-module checklist, not a replacement for the detailed component specifications. See [`specifications/decimal-math.md`](specifications/decimal-math.md) for the complete decimal-math contract.

## 1. Decimal math

### Mental model

Solidity stores integers. Token and oracle decimals define how those integers should be interpreted; decimals are not quantities that should be multiplied or divided directly.

```text
human value = stored integer / 10^decimals
```

A WAD is an 18-decimal fixed-point unit:

```text
1 WAD   = 1e18
0.5 WAD = 5e17
```

Normalize values into one common unit before comparing, adding, or using them in protocol-wide accounting.

### Core operations

#### Scale between decimal systems

```text
fromDecimals < toDecimals: amount * 10^(toDecimals - fromDecimals)
fromDecimals > toDecimals: amount / 10^(fromDecimals - toDecimals)
```

Scaling up is exact. Scaling down can lose precision and therefore requires an explicit rounding direction.

#### Calculate value in WAD

For an asset amount and price:

```text
normalizedPrice = scale(price, priceDecimals, 18)
valueInWad = amount * normalizedPrice / 10^amountDecimals
```

Example:

```text
amount = 2e18          // 2 ETH
price  = 2000e8        // $2,000 with 8 decimals
value  = 4000e18       // $4,000 in WAD
```

#### Calculate a WAD ratio

```text
ratioWad = numerator * 1e18 / denominator
```

Example:

```text
80 / 100 = 0.8e18
```

### Rounding policy

Rounding is a protocol policy, not an implementation detail.

Typical conservative choices:

| Operation | Common direction | Reason |
|---|---:|---|
| Shares minted for assets | Floor | Do not over-mint claims |
| Assets returned for shares | Floor | Do not overpay withdrawals |
| Shares required for withdrawal | Ceil | Burn enough shares |
| Debt created or owed | Ceil | Do not understate debt |
| Collateral value | Floor | Do not overstate safety |
| Liquidation repayment requirement | Ceil | Ensure sufficient repayment |

The correct direction depends on who must be protected and which side receives the rounding remainder.

### Decimal-math checklist

- [ ] Every value has a documented unit and decimal count.
- [ ] Values are normalized before addition or comparison.
- [ ] Full-precision `mulDiv` is used for multiplication followed by division.
- [ ] Rounding is explicit at every precision-loss boundary.
- [ ] Division-by-zero behavior is explicit.
- [ ] Supported decimal ranges are validated.
- [ ] Scaling up and scaling down are tested separately.
- [ ] Floor and ceil cases use inputs with a real remainder.
- [ ] Tests include zero, equal-decimal, boundary, and unsupported-decimal cases.
- [ ] Large values are tested for overflow resistance.

## 2. ERC-20 integration model

### Interface compatibility is not economic correctness

`SafeERC20` handles common call-level incompatibilities:

- a token returns `true`;
- a token returns `false`;
- a token returns no data;
- a token reverts.

It does not prove that the expected number of tokens moved.

```text
SafeERC20 answers: did the token call report success?
Balance deltas answer: what economic change actually occurred?
```

### Keep three quantities separate

```text
requested: amount supplied to transfer/transferFrom
spent:     decrease in the sender's balance
received:  increase in the recipient's balance
```

| Token behavior | Requested | Spent | Received |
|---|---:|---:|---:|
| Standard | 100 | 100 | 100 |
| Fee deducted from transfer | 100 | 100 | 90 |
| Additional sender fee | 100 | 110 | 100 |

Never assume these values are equal unless the integration explicitly enforces it.

## 3. Transfer policies

### Pull operations: user to protocol

`pullExact` requires the protocol to receive exactly the requested amount:

```text
protocol balance after - protocol balance before == requested
```

Its current policy does not measure total sender spend. An additional-sender-fee token can therefore be accepted if the protocol still receives the exact requested amount. This must remain an intentional and documented decision.

`pullBalanceDelta` accepts variable receipt and returns the actual amount received. Higher-level accounting must credit `received`, never the requested amount.

### Push operations: protocol to recipient

`pushExact` measures both sides:

```text
spent    = protocol balance before - protocol balance after
received = recipient balance after - recipient balance before
```

It accepts the operation only when:

```text
spent == requested && received == requested
```

`pushBalanceDelta` returns both values without enforcing equality. The caller must apply the appropriate policy.

### Transfer checklist

- [ ] Zero token addresses are rejected deterministically.
- [ ] Zero-amount behavior is explicitly supported or rejected.
- [ ] Pushes to the zero address are explicitly handled.
- [ ] Pushes to `address(this)` are rejected or documented as unsupported.
- [ ] Exact and permissive balance-delta modes are not confused.
- [ ] Fee deducted from transfer is tested.
- [ ] Additional sender fee is tested.
- [ ] False-return tokens revert through `SafeERC20`.
- [ ] Successful no-return tokens are supported when intended.
- [ ] Exact-transfer failure tests prove full rollback of balances and allowances.
- [ ] Tests assert exact custom errors and arguments where practical.

### Atomic rollback

If an exact-transfer post-condition fails after the token call, reverting rolls back all nested changes made in that transaction:

- token balances;
- collected transfer fees;
- allowance reduction;
- protocol accounting.

A revert restores the complete pre-transaction state, not the state immediately before the final check.

## 4. Token callbacks and reentrancy

### Mental model

Every call to an external token is an untrusted external interaction, including calls that look routine:

```solidity
token.balanceOf(account);
token.transfer(receiver, amount);
token.transferFrom(sender, receiver, amount);
token.approve(spender, amount);
```

A malicious or extended token can call back into the protocol before the original operation finishes.

### Vulnerable stale-state pattern

```text
read user balance
call token
token reenters and uses the same old balance
write a result derived from the stale balance
```

The demonstrated attack withdrew twice against one recorded deposit and left the bank insolvent:

```text
bank assets < recorded user liabilities
```

### Defensive model

- Apply checks-effects-interactions where the required amount is already known.
- Apply `nonReentrant` to every external entry point sharing the protected invariant.
- For deposits, the interaction may be needed before accounting because actual receipt is not known until after `transferFrom`; a reentrancy guard is particularly important.
- Do not assume a transfer library protects unrelated protocol storage.
- Consider cross-function and cross-token reentrancy, not only recursion into the same function.
- Remember read-only reentrancy: external observers may see temporarily inconsistent state.

### Reentrancy checklist

- [ ] All external calls are identified, including token calls.
- [ ] State changes occur before interaction when possible.
- [ ] All entry points sharing an invariant use a consistent guard strategy.
- [ ] Callback failure and full rollback are tested.
- [ ] Adversarial tests use an attacker contract when the nested call must preserve attacker identity.
- [ ] Tests verify economic impact, not merely that a callback occurred.
- [ ] Asset solvency is asserted after every successful operation.

## 5. Allowance management

### Identify the roles

```text
owner:       account whose tokens can be moved
spender:     account authorized by the owner
destination: account receiving the transferred tokens
```

These roles are independent. An approval cannot be forwarded:

```text
user approves adapter + adapter approves router
does not mean user approved router
```

A user-funded integration therefore has two separate movements:

```text
user --transferFrom--> adapter --transferFrom--> external spender
```

### Exact set-call-clear lifecycle

```text
validate token and spender
snapshot adapter balance
forceApprove exact amount
call spender
forceApprove zero
measure actual spend
validate post-condition
```

The successful-operation invariant is:

```text
allowance(adapter, spender) == 0
```

### Zero-first tokens

A zero-first token rejects a direct non-zero to non-zero allowance change:

```text
allowance 1 -> 100: revert
allowance 1 -> 0 -> 100: success
```

`forceApprove` provides compatibility by attempting the direct update and falling back to a zero-reset sequence.

### Why cleanup remains important

If a spender uses less than the approved amount, the remainder otherwise stays authorized and can affect tokens received by the adapter later.

```text
approved = 100
spent    = 60
residual = 40
```

Exact approval only limits how much the spender can take. It does not prove that the external integration produced a useful result. Swap and protocol adapters must separately validate output tokens, recipients, slippage, deadlines, and balance deltas.

### Revert nuance

If execution resets the allowance to zero and then reverts during a post-condition, the cleanup is also reverted.

```text
allowance before transaction = 1
transaction eventually reverts
allowance after transaction  = 1
```

Successful operations should end with zero allowance. Failed operations restore the allowance that existed before the transaction.

### Exact versus maximum input

| Operation | Allowed spend | Required handling |
|---|---:|---|
| Exact input | Exactly `amountIn` | Revert if actual spend differs |
| Maximum input | At most `maxAmountIn` | Clear allowance and refund/account for unused input |

The current adapter implements exact input. Maximum-input behavior belongs in a separate function or adapter with its own specification.

### Allowance checklist

- [ ] Token and spender are validated before approval.
- [ ] The approved owner matches the `from` address used by `transferFrom`.
- [ ] Exact or maximum approval policy is explicit.
- [ ] `forceApprove` is used when zero-first compatibility is required.
- [ ] Approval is established immediately before the external call.
- [ ] Residual allowance is cleared after a successful call.
- [ ] Actual spend is measured with a balance delta.
- [ ] Exact-spend mismatch reverts.
- [ ] Excessive-spend attempts fail at the token allowance boundary.
- [ ] Partial-spend behavior and rollback are tested.
- [ ] Reentrancy during the spender call is tested.
- [ ] A successful call ends with zero allowance.
- [ ] Trusted-spender policy is independent from allowance-size policy.

## 6. Testing strategy

### Unit tests

Unit tests establish the component specification under controlled behavior:

- supported inputs and boundary conditions;
- exact return values;
- expected state transitions;
- precise custom errors;
- standard and documented compatibility cases.

### Adversarial tests

Adversarial tests model hostile or abnormal counterparties:

- fee-on-transfer and additional-sender-fee tokens;
- false and missing return values;
- partial or excessive external spending;
- callback and cross-function reentrancy;
- stale accounting and insolvency;
- attempts to use residual approval.

### Fuzz properties

Useful properties for these primitives include:

```text
scale(scale(x, a, b, Floor), b, a, Floor) <= x
pullExact success => received == requested
pushExact success => spent == requested && received == requested
executeExact success => actualSpent == requested
executeExact success => allowance(adapter, spender) == 0
```

Round-trip scaling is not generally equal when scaling down loses precision; the property must encode the rounding relationship rather than demand equality.

### Invariants

Higher-level protocols should continuously assert properties such as:

```text
token assets held by protocol >= token-denominated liabilities
sum of user balances <= protocol assets
successful exact operations leave no residual spender allowance
unauthorized accounts cannot reduce another user's claim
```

Coverage confirms that implementation paths were executed. Assertion quality, adversarial models, fuzz properties, invariants, and review determine whether the exercised behavior was actually correct.

## 7. Integration review mental model

For each external asset movement, answer these questions explicitly:

1. What is the unit and decimal system of every value?
2. Which direction should rounding favor?
3. Who is the token owner, spender, and recipient?
4. What amount was requested?
5. What amount did the sender actually spend?
6. What amount did the recipient actually receive?
7. Which token behaviors are supported, normalized, or rejected?
8. Can any token or spender call back into the protocol?
9. Which state invariant is temporarily or permanently affected?
10. What allowance remains after success?
11. What complete state is restored after failure?
12. Which unit, adversarial, fuzz, and invariant tests prove the policy?

This checklist should be applied again when building vaults, lending markets, swaps, staking adapters, stablecoin reserves, liquidation flows, and protocol integrations.
