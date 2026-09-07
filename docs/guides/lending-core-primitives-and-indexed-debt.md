# Lending Core Primitives: Risk, Liquidations, Rates, and Indexed Debt

This guide summarizes the lending milestone implemented in `defi-protocol-lab`.

It is intended as:

- a mental-model refresher for lending protocol engineering;
- a review checklist before changing lending code;
- an interview-preparation note;
- a compact reference for explaining difficult lending primitives clearly;
- a bridge from the lab implementation toward production architectures such as Aave-style indexed accounting.

The milestone intentionally progressed from a simple static-debt lending pool to a time-dependent indexed-debt model. The important result is not only the code, but the reasoning about **units, risk boundaries, rounding, ordering, lazy accrual, and protocol-wide accounting invariants**.

---

## 1. Milestone scope

The lending epic covered these layers:

1. collateral custody;
2. borrow capacity;
3. health factor;
4. collateral withdrawals;
5. debt repayment;
6. liquidation mechanics;
7. bad-debt reasoning;
8. utilization-based interest rates;
9. borrow/supply rate economics;
10. simple time accrual;
11. borrow-index accounting;
12. scaled debt;
13. lazy interest accrual;
14. integration of indexed debt back into `SimpleLendingPool`.

The final mental model is:

```text
collateral
    ↓
oracle valuation
    ↓
LTV / liquidation threshold
    ↓
borrow / health factor / liquidation

available debt-token liquidity + total debt
    ↓
utilization
    ↓
borrow rate
    ↓
elapsed time
    ↓
borrow index
    ↓
scaled debt × current index
    ↓
current economic debt
    ↓
health factor / utilization / liquidation risk
```

The important design shift was:

```text
static nominal debt
→ scaled debt + global borrow index
```

This lets debt grow with time without updating every borrower in storage.

---

# 2. Minimal lending model

The lab starts with a deliberately small market:

```text
Collateral token: WETH
Debt token:       USDC
Oracle:           WETH/USD
```

Risk constants:

```text
LTV                     = 75%
LIQUIDATION_THRESHOLD   = 80%
LIQUIDATION_BONUS       = 5%
CLOSE_FACTOR            = 50%
```

The simplified model treats USDC as:

```text
1 USDC ≈ $1
```

so collateral and debt can be compared in the same quote currency.

This is a lab assumption, not a production requirement. A production protocol normally values both sides independently in one common quote currency.

---

# 3. Collateral custody

## Core invariant

Successful collateral accounting must correspond to actual token custody.

```text
protocol accounting claim
must match
tokens actually received
```

The pool uses exact token pulling:

```text
TokenTransfer.pullExact(...)
```

This rejects fee-on-transfer behavior where the protocol receives less than requested.

Example:

```text
user supplies:       1 WETH
protocol receives:   1 WETH
recorded collateral: 1 WETH
```

If a token transfers only `0.99 WETH`, the operation reverts rather than crediting `1 WETH`.

### Important distinction

A direct unsolicited ERC-20 transfer into the pool does not automatically create a collateral claim.

```text
token balance of pool
!=
sum of protocol-accounted collateral
```

Protocol accounting is authoritative for user claims.

---

# 4. Collateral valuation

Oracle prices are normalized to WAD:

```text
priceWad = price with 18 decimals
```

Example:

```text
ETH/USD = 2000e18
1 WETH  = 1e18
```

Collateral value:

```text
collateralValueWad
=
token amount × normalized price
```

For:

```text
1 WETH @ $2000
```

the result is:

```text
2000e18
```

### Rounding policy

Collateral contribution uses conservative rounding:

```text
collateral value → Floor
```

Reason:

> Do not overstate borrower safety.

---

# 5. LTV: creating risk

LTV defines how much debt a borrower may create.

```text
maxBorrowValue
=
collateralValue × LTV
```

Example:

```text
1 WETH = $2000
LTV    = 75%
```

Then:

```text
max borrow = $1500
```

For USDC:

```text
1500e6
```

## Key semantic distinction

`collateralValue()` returns:

```text
quote currency WAD
```

while `maxBorrow()` returns:

```text
debt-token native units
```

Do not compare values with different units without normalization.

---

# 6. LTV versus liquidation threshold

This is one of the most important lending concepts.

## LTV

Controls **risk creation**.

```text
Can the borrower create more debt?
```

## Liquidation threshold

Controls **liquidation safety**.

```text
Is the existing position liquidatable?
```

Example:

```text
collateral value = $1900
LTV 75%          = $1425 max borrow
LT 80%           = $1520 liquidation-adjusted collateral
existing debt    = $1500
```

Result:

```text
availableToBorrow = 0
```

because:

```text
1500 > 1425
```

but the position is still healthy because:

```text
1520 / 1500 > 1
```

Therefore:

> A position can exceed current LTV capacity without being liquidatable.

This distinction is frequently tested in senior DeFi interviews.

---

# 7. Health factor

The health factor is a WAD ratio:

```text
HF
=
(collateralValue × liquidationThreshold)
/
debtValue
```

Interpretation:

```text
HF > 1e18  → healthy
HF = 1e18  → exact liquidation boundary
HF < 1e18  → liquidatable
```

If there is no debt:

```text
HF = type(uint256).max
```

which models effectively infinite safety.

## Numeric example

```text
Collateral = 1 WETH
Price      = $2000
Debt       = $1500
LT         = 80%
```

Adjusted collateral:

```text
2000 × 0.80 = 1600
```

Health factor:

```text
1600 / 1500
= 1.066666...
```

WAD:

```text
1_066_666_666_666_666_666
```

### Conservative rounding

A useful risk policy is:

```text
collateral contribution → Floor
debt contribution       → Ceil
health-factor ratio      → Floor / Trunc
```

The system should not overstate borrower safety.

---

# 8. Collateral withdrawal

A borrower may withdraw collateral only if the resulting position remains healthy.

Important flow:

```text
check amount
↓
reduce collateral accounting
↓
calculate resulting HF
↓
require HF >= 1
↓
transfer collateral
```

This is a useful example of state-first validation:

```text
effects
→ validate resulting state
→ external interaction
```

If validation fails, EVM rollback restores the previous collateral balance.

## Why withdrawal uses liquidation threshold

Borrowing uses LTV.

Withdrawal asks whether the **resulting existing position remains safe**, therefore it uses health factor / liquidation threshold.

This means:

```text
borrow capacity rule != withdrawal safety rule
```

---

# 9. Repayment

Repayment reduces debt and returns debt-token liquidity to the pool.

A subtle ordering lesson appeared here.

The safer flow is:

```text
validate repayment
↓
pull debt token
↓
reduce debt accounting
```

rather than reducing debt before the token transfer.

Why?

If a malicious debt token can callback during `transferFrom`, it should see the borrower's **old, conservative debt**, not an already-reduced debt balance that could temporarily make additional collateral withdrawal possible.

This demonstrates an important protocol-security lesson:

> Checks-effects-interactions is not a mechanical rule. The correct ordering depends on which intermediate state an external callback could exploit.

Always analyze cross-function reentrancy, not only recursion into the same function.

---

# 10. Liquidation mechanics

Liquidation lets a third party repay some borrower debt and receive discounted collateral.

Core parameters:

```text
close factor       = 50%
liquidation bonus  = 5%
```

## Maximum liquidatable debt

```text
maxLiquidatableDebt
=
currentDebt × closeFactor
```

For:

```text
debt = 1500 USDC
close factor = 50%
```

the liquidator may repay at most:

```text
750 USDC
```

---

# 11. Liquidation collateral seizure

The economic sequence is:

```text
debtToRepay
→ quote value
→ apply liquidation bonus
→ divide by collateral price
→ collateral amount to seize
```

Example:

```text
repay               = $750
liquidation bonus   = 5%
seize value         = $787.50
ETH price           = $1800
```

Collateral seized:

```text
787.5 / 1800
= 0.4375 WETH
```

Important decimal path:

```text
debt native units
→ quote WAD
→ bonus-adjusted quote WAD
→ collateral native units
```

Do not accidentally scale debt directly into collateral decimals.

That bug can be hidden when collateral happens to have 18 decimals.

---

# 12. Liquidation lifecycle

Canonical flow:

```text
borrower must be unhealthy
↓
debtToRepay <= close-factor limit
↓
calculate collateral to seize
↓
ensure borrower owns enough collateral
↓
pull debt tokens from liquidator
↓
reduce borrower debt
↓
reduce total debt
↓
reduce borrower collateral
↓
send collateral to liquidator
```

After indexed debt was introduced, the state-changing flow became:

```text
_accrueInterest()
↓
evaluate borrower using committed current index
↓
pull liquidator debt tokens
↓
convert actual repayment to scaled debt reduction
↓
reduce borrower scaled debt
↓
reduce totalScaledDebt
↓
reduce collateral
↓
send seized collateral
```

---

# 13. Why liquidation does not need to restore HF above 1

A common mistake is to require:

```text
HF after liquidation >= 1
```

That is incorrect.

Liquidation may reduce absolute protocol exposure even when the position remains unhealthy.

For a deeply underwater position, liquidation can even make the health factor numerically worse because both debt and collateral are removed.

Liquidation success criteria are not:

```text
HF must improve
```

or:

```text
HF must become healthy
```

The real economic objective is:

```text
reduce risky debt exposure under protocol rules
```

---

# 14. Bad debt

Health factor below 1 does not automatically mean bad debt.

## Liquidatable position

```text
liquidation-adjusted collateral < debt
```

## Bad debt / insolvency

Economically:

```text
raw collateral value < debt value
```

Example:

```text
collateral = $1000
debt       = $1500
```

The protocol has:

```text
$500 deficit
```

Liquidation cannot create missing collateral.

Possible production responses include:

- reserve or treasury absorption;
- insurance / safety funds;
- staker slashing;
- auctions;
- socialized losses;
- governance recapitalization;
- explicit deficit accounting.

The lab intentionally does not implement these mechanisms.

### Core lesson

> Liquidation reduces risk. It does not guarantee solvency.

Protocol solvency also depends on:

- oracle latency;
- price gaps;
- liquidation liquidity;
- liquidator participation;
- gas conditions;
- market depth;
- protocol risk parameters.

---

# 15. Close factor

A close factor limits how much debt can be liquidated in one operation.

Reasons include:

- avoiding unnecessary over-liquidation;
- limiting discounted collateral seizure;
- reducing market impact;
- reducing slippage and MEV exposure;
- allowing partial liquidation to restore health;
- limiting one transaction's impact on the borrower.

It is a **risk-control parameter**, not a mechanism that solves bad debt.

---

# 16. Utilization

Once the static lending mechanics were complete, the next layer was reserve economics.

Utilization:

```text
U
=
totalDebt
/
(availableLiquidity + totalDebt)
```

Examples:

```text
available = 800
debt      = 200
U         = 20%
```

```text
available = 200
debt      = 800
U         = 80%
```

```text
available = 0
debt      = 1000
U         = 100%
```

Collateral does not participate in this formula.

This is a critical separation:

```text
collateral / HF / liquidation
→ credit risk

available debt-token liquidity / utilization / rates
→ liquidity economics
```

---

# 17. Why borrowing rates depend on utilization

High utilization means:

```text
little liquidity remains available
```

The protocol increases borrowing rates to:

- discourage additional borrowing;
- encourage repayments;
- increase supplier yield;
- attract additional liquidity.

So utilization creates a feedback loop between borrowers and suppliers.

---

# 18. Kinked interest-rate model

The lab uses:

```text
BASE_RATE            = 2%
SLOPE1               = 4%
SLOPE2               = 75%
OPTIMAL_UTILIZATION  = 80%
```

## Below the kink

```text
rate
=
base
+
slope1 × (U / optimalU)
```

Examples:

```text
U = 0%
rate = 2%
```

```text
U = 40%
rate = 2% + 4% × (40 / 80)
     = 4%
```

```text
U = 80%
rate = 6%
```

## Above the kink

Normalize utilization inside the post-kink interval:

```text
excess progress
=
(U - optimalU)
/
(1 - optimalU)
```

At:

```text
U = 90%
optimal = 80%
```

progress is:

```text
(90 - 80) / (100 - 80)
= 50%
```

Rate:

```text
6% + 75% × 50%
= 43.5%
```

At 100%:

```text
81%
```

### Important fixed-point lesson

Naive integer division:

```text
0.1e18 / 0.2e18
```

returns zero if treated as ordinary integer division.

A WAD ratio helper is required:

```text
ratioWad(...)
```

This was one of the key reasons for the earlier `DecimalMath` foundation.

---

# 19. Supply rate and reserve factor

Borrow interest is paid only by borrowed capital but distributed across all supplied capital.

Approximate gross supplier rate:

```text
supplyRateGross
=
borrowRate × utilization
```

With a reserve factor:

```text
supplierRate
=
borrowRate
× utilization
× (1 - reserveFactor)
```

Example:

```text
borrow APR      = 10%
utilization     = 50%
reserve factor  = 10%
```

Gross supply APR:

```text
10% × 50%
= 5%
```

Net supplier APR:

```text
5% × 90%
= 4.5%
```

Reserve factor means:

> the protocol receives a fraction of generated interest.

It does **not** mean subtracting 10 percentage points from APR.

---

# 20. Annual rate versus accrued interest

A rate is only a parameter.

It does not change borrower debt until time is accounted for.

Simple linear interest:

```text
interest
=
principal
× annualRate
× elapsedTime / year
```

Example:

```text
principal = 1000 USDC
APR       = 10%
elapsed   = 1 year
```

Interest:

```text
100 USDC
```

For half a year:

```text
50 USDC
```

The lab used simple interest as a bridge toward index accounting.

---

# 21. Why per-user accrual does not scale

A naive design might store each user's debt and update every borrower when time passes.

That would require:

```text
for each borrower:
    debt += accruedInterest
```

This is impossible at protocol scale.

With 100,000 borrowers, an on-chain loop over all borrowers is not viable.

The solution is:

```text
one global borrow index
+
per-user scaled debt
```

---

# 22. Borrow index

The index is a global debt multiplier.

Initial value:

```text
borrowIndex = 1e18
```

which means:

```text
1.0
```

If rate is 10% for one year:

```text
index:
1.00
→ 1.10
```

The update is:

```text
indexGrowth
=
currentIndex × rate × elapsed / year
```

```text
newIndex
=
currentIndex + indexGrowth
```

If another year passes and the index has already been committed to 1.10:

```text
1.10 × 10% = 0.11
new index  = 1.21
```

So the interval formula is linear, but repeated index updates create compounding across intervals.

---

# 23. Scaled debt

Instead of storing changing nominal debt:

```text
_debtBalance[user]
```

store:

```text
_scaledDebt[user]
```

Actual debt is reconstructed:

```text
actualDebt
=
scaledDebt × borrowIndex / 1e18
```

## Example

Current index:

```text
1.25
```

User borrows:

```text
1000 USDC
```

If storage saved `1000`, the reconstructed debt would immediately become:

```text
1250
```

which would incorrectly charge historical interest.

Instead:

```text
scaledDebt
=
1000 / 1.25
=
800
```

Then:

```text
800 × 1.25
=
1000
```

If the index later rises to:

```text
1.40
```

without changing user storage:

```text
800 × 1.40
=
1120 USDC
```

This is the central indexed-accounting insight:

```text
scaled balance stays constant
while
economic debt grows with the index
```

---

# 24. Borrow and repay rounding

Debt accounting requires asymmetric rounding.

## Borrow: actual → scaled

New debt must not be understated.

```text
scaled borrow delta
=
actual borrow / index
```

Use:

```text
Ceil
```

## Repay: actual → scaled reduction

Repayment must not burn more debt than was economically paid.

```text
scaled repay delta
=
actual repayment / index
```

Use:

```text
Floor
```

This yields:

```text
borrow → round debt creation up
repay  → round debt reduction down
```

---

# 25. Full-repay special case

Floor conversion can leave dust.

If:

```text
repayment == current actual debt
```

the protocol should clear the user's entire scaled balance:

```text
_scaledDebt[user] = 0
```

and reduce:

```text
totalScaledDebt
```

by the complete stored user scaled balance.

Otherwise a user could fully repay the quoted debt yet retain tiny residual scaled debt.

---

# 26. Tiny debt-reduction edge case

For partial repayment:

```text
scaledDelta
=
floor(actualAmount × 1e18 / index)
```

If:

```text
actualAmount > 0
```

but:

```text
scaledDelta == 0
```

the operation must revert.

Otherwise tokens could be transferred while accounting debt remains unchanged.

This motivated:

```text
DebtReductionTooSmall
```

The same concern applies to scaled reductions during liquidation.

---

# 27. Global scaled debt

The same scalability principle applies to total reserve debt.

Store:

```text
totalScaledDebt
```

Then:

```text
totalDebt
=
totalScaledDebt × borrowIndex
```

No borrower iteration is required.

This solves two scalability problems:

```text
per-user debt accrual without iteration
+
reserve-wide debt accrual without iteration
```

---

# 28. Lazy accrual

The final pool uses **lazy accrual**.

Storage contains:

```text
borrowIndex
lastInterestUpdate
totalScaledDebt
_scaledDebt[user]
```

Time may pass without any transaction.

The stored index remains unchanged, but view functions can calculate the index that should apply now.

Conceptually:

```text
stored borrowIndex
+
virtual accrual since last update
=
currentBorrowIndex()
```

This allows:

```text
debtOf(user)
```

to show current economic debt even if no state-changing transaction has happened.

---

# 29. Stored index versus current index

This distinction is critical.

## Stored index

```text
borrowIndex
```

The last index committed to storage.

## Current / preview index

```text
currentBorrowIndex()
```

The index that should apply at the current timestamp if accrued virtually.

Example:

```text
stored index   = 1.00
current index  = 1.06
```

A read can expose debt using `1.06` without storing it.

Then:

```text
_accrueInterest()
```

materializes the value:

```text
borrowIndex = 1.06
lastInterestUpdate = now
```

Important invariant:

```text
preview index immediately before accrual
==
stored index immediately after accrual
```

assuming no other state changes occur.

---

# 30. Why stored utilization exists

This was one of the most subtle parts of the milestone.

A naive dependency graph becomes recursive:

```text
currentBorrowIndex
→ current debt
→ utilization
→ borrow rate
→ currentBorrowIndex
```

To calculate the interest for the elapsed interval, the model therefore uses the **last committed reserve state**.

Stored total debt:

```text
totalDebtAtStoredIndex
=
totalScaledDebt × stored borrowIndex
```

Stored utilization:

```text
storedUtilization
=
storedDebt
/
(availableLiquidity + storedDebt)
```

Then:

```text
stored utilization
→ interval borrow rate
→ currentBorrowIndex preview
```

No recursion.

### Mental model

```text
stored utilization
→ rate used for the elapsed interval

current utilization
→ observable utilization of the virtually accrued current state
```

These represent different temporal semantics.

---

# 31. Current borrow rate versus interval borrow rate

These should not be confused.

## Interval borrow rate

Derived from:

```text
stored utilization
```

Used to accrue the period since the last committed update.

## Current borrow rate

Derived from:

```text
current utilization
```

It answers:

> What rate does the reserve's current economic state imply now?

This distinction became visible after debt accrual pushed utilization above the kink.

---

# 32. Dynamic feedback loop

A particularly useful integration scenario was:

```text
pool capital = 10,000 USDC
debt         = 8,000 USDC
available    = 2,000 USDC
```

Initial utilization:

```text
80%
```

Initial borrow rate:

```text
6%
```

After one year at the stored interval rate:

```text
borrowIndex:
1.00 → 1.06
```

Current debt:

```text
8000 → 8480
```

Current utilization:

```text
8480 / (8480 + 2000)
≈ 80.916%
```

Now utilization is above the kink, so the current borrow rate rises to about:

```text
9.435%
```

This proves the feedback chain:

```text
time
→ debt grows
→ utilization grows
→ borrow rate grows
```

The lending system is now dynamic rather than a set of independent formulas.

---

# 33. Accrue before mutate

State-changing debt operations first commit historical interest.

## Borrow

```text
_accrueInterest()
↓
read existing current debt
↓
check LTV
↓
convert new borrow to scaled units at current index
↓
increase scaled debt
```

Why?

A new borrow must not receive interest for time before it existed.

## Repay

```text
_accrueInterest()
↓
read current debt
↓
pull repayment
↓
reduce scaled debt
```

Why?

The borrower must pay interest accrued before the repayment.

## Liquidation

```text
_accrueInterest()
↓
evaluate current HF
↓
calculate liquidation limits
↓
reduce scaled debt
```

Why?

Liquidation must operate on the borrower's economically current debt.

This general principle is:

> Accrue the old state to the current time before applying a state mutation that changes future economics.

---

# 34. Interest can trigger liquidation without a price move

Initially:

```text
collateral price = unchanged
collateral amount = unchanged
```

But:

```text
time passes
→ debt increases
→ HF decreases
```

Eventually:

```text
HF < 1
```

The borrower can become liquidatable purely because of accrued borrowing cost.

This is a crucial shift from the earlier static-debt pool, where liquidation risk was driven mainly by oracle price movement.

---

# 35. Public views versus state-changing paths

A useful architecture convention emerged.

## Read paths

Use:

```text
current / preview borrow index
```

so callers observe current economic state.

Examples:

```text
debtOf(user)
totalDebt()
healthFactor(user)
utilization()
currentBorrowRate()
```

## State-changing debt paths

First call:

```text
_accrueInterest()
```

Then mutate balances against the committed current `borrowIndex`.

This separation makes lazy accrual predictable.

---

# 36. Rounding policy summary

| Operation | Direction | Reason |
|---|---:|---|
| Collateral value | Floor | Do not overstate safety |
| Debt value | Ceil | Do not understate liability |
| HF final ratio | Floor / Trunc | Do not overstate safety |
| Borrow actual → scaled | Ceil | Do not under-create debt |
| Repay actual → scaled reduction | Floor | Do not forgive extra debt |
| Liquidation actual → scaled reduction | Floor | Do not remove more borrower debt than was repaid |
| Scaled debt → actual debt | Ceil | Do not understate current liability |
| Borrow-index growth | Conservative upward rounding | Avoid understating accrued debt |

The exact production policy can vary, but the direction must be intentional.

---

# 37. Protocol accounting invariants

The most useful invariants from this milestone are:

## User debt reconstruction

```text
debtOf(user)
≈
_scaledDebt[user] × currentBorrowIndex / 1e18
```

with conservative rounding.

## Reserve debt reconstruction

```text
totalDebt()
≈
totalScaledDebt × currentBorrowIndex / 1e18
```

## Index monotonicity

With non-negative rates:

```text
newBorrowIndex >= oldBorrowIndex >= 1e18
```

## Index-only update

When only the index changes:

```text
_scaledDebt[user] unchanged
totalScaledDebt unchanged
actual user debt increases
actual total debt increases
```

## Borrow

```text
actual resulting debt <= LTV-based max debt
```

## Repay

```text
actual repayment <= current actual debt
```

## Liquidation

```text
borrower HF < 1
debtToRepay <= close-factor limit
collateral seized <= borrower collateral
```

## Preview/commit consistency

```text
currentBorrowIndex() before accrue
==
borrowIndex after accrue
```

at the same timestamp and reserve state.

---

# 38. Testing strategy

Coverage is useful, but branch percentage is not the protocol specification.

The milestone reached complete line/function coverage while some defensive internal branches remained difficult or impossible to reach through normal external flows.

Do not create artificial tests only to turn every LCOV branch green.

Prioritize economically meaningful behavior.

## High-value unit tests

### Collateral

- exact custody;
- repeated supply;
- multiple users;
- fee-on-transfer rejection;
- insufficient allowance rollback.

### Borrow

- exact max borrow;
- max + 1 revert;
- cumulative borrow;
- LTV capacity after price movement;
- new borrow after elapsed time does not receive historical interest.

### Health factor

- no debt;
- healthy;
- exact boundary;
- liquidatable;
- interest alone decreases HF;
- interest alone can eventually make HF < 1.

### Repay

- partial;
- full;
- > debt revert;
- transfer failure rollback;
- full repay removes complete scaled balance;
- tiny debt reduction that maps to zero scaled units reverts.

### Liquidation

- canonical healthy-to-unhealthy price move;
- close factor;
- collateral bonus;
- collateral exhaustion;
- insufficient liquidator allowance rollback;
- scaled borrower debt reduction;
- global scaled debt reduction.

### Indexing

- initial index;
- virtual index growth;
- stored index unchanged before commit;
- preview equals committed index;
- sequential index accrual;
- current debt grows without user storage writes.

### Reserve economics

- utilization 0 / low / kink / full;
- rate below and above kink;
- debt growth increases utilization;
- utilization crossing the kink raises current rate.

---

# 39. Coverage lesson

A useful rule:

```text
100% executed paths
!=
100% correct protocol
```

Higher-value confidence comes from:

- economic invariants;
- exact unit reasoning;
- adversarial transfer behavior;
- rounding boundaries;
- rollback assertions;
- time-dependent state transitions;
- multi-user/global accounting;
- fuzz tests;
- invariant tests.

A branch that cannot occur through valid protocol state may be less important than a lifecycle test that proves the entire economic feedback loop.

---

# 40. Common implementation mistakes

## Comparing scaled and actual units

Wrong:

```text
scaledDebt <= maxBorrowUSDC
```

These are different representations.

Correct:

```text
actualDebt <= maxBorrowUSDC
```

Scaled balances are storage units; risk checks use economic debt.

---

## Charging historical interest on new borrow

Wrong:

```text
add new debt
then accrue old interval
```

Correct:

```text
accrue old interval
then add new debt
```

---

## Repaying before accrual

Wrong:

```text
reduce debt
then accrue past interest
```

This lets the borrower avoid historical interest.

Correct:

```text
accrue
then repay
```

---

## Using current debt to compute current index

This creates:

```text
index → debt → utilization → rate → index
```

Use last committed reserve state to determine the elapsed interval rate.

---

## Updating nominal debt directly

Once scaled debt is introduced, do not maintain a parallel `_totalDebt` nominal source of truth.

Avoid:

```text
totalScaledDebt
+
_totalDebt
```

Two accounting representations create drift risk.

---

## Full repay using only floor-scaled reduction

This can leave dust.

Use explicit full-repay clearing.

---

## Using ceil for partial repayment reduction

This can forgive borrower debt.

Partial repay reduction should normally round down.

---

## Assuming liquidation always improves HF

Deeply underwater positions disprove this.

---

## Treating low utilization and high collateral as related

They model different systems:

```text
collateral risk
vs
reserve liquidity
```

---

# 41. Senior / interview questions

Use these as self-review prompts.

## Lending risk

**Q: What is the difference between LTV and liquidation threshold?**

Expected answer:

- LTV limits risk creation / new borrowing.
- Liquidation threshold determines when existing debt can be liquidated.
- A user can be above LTV capacity but still have HF > 1.

---

**Q: Why is health factor not the same as collateralization ratio?**

Expected answer:

HF includes the protocol's liquidation threshold:

```text
HF = collateral value × LT / debt
```

It is a protocol risk metric, not simply raw collateral/debt.

---

**Q: Can a position be liquidatable but not insolvent?**

Yes.

HF < 1 means the protocol permits liquidation.

Bad debt means raw collateral value is below debt.

These are not equivalent.

---

**Q: Does liquidation guarantee solvency?**

No.

Large price gaps, oracle delays, insufficient liquidation liquidity, market depth, or extreme volatility can leave bad debt.

---

**Q: Why use a close factor?**

To limit over-liquidation, discounted collateral seizure, market impact, slippage, and single-transaction liquidation size.

---

## Interest-rate economics

**Q: What is utilization?**

```text
debt / (available liquidity + debt)
```

It measures how much reserve capital is borrowed.

---

**Q: Why do borrow rates rise at high utilization?**

To reduce borrowing demand, encourage repayment, increase supplier yield, and attract liquidity.

---

**Q: Why use a kinked rate curve?**

To keep normal borrowing relatively cheap around healthy utilization while strongly penalizing liquidity scarcity above the target utilization.

---

**Q: Why is the post-kink expression normalized?**

```text
(U - optimalU) / (1 - optimalU)
```

maps the interval:

```text
[optimalU, 100%]
→
[0, 1]
```

so `SLOPE2` can represent the maximum additional rate across the full post-kink range.

---

**Q: What is the reserve factor?**

The protocol's share of generated borrower interest.

It is not a flat APR subtraction.

---

## Indexed accounting

**Q: Why not store current borrower debt directly?**

Because interest accrues continuously over time. Updating every borrower would require iteration and does not scale.

---

**Q: What is scaled debt?**

A time-independent accounting unit such that:

```text
actual debt
=
scaled debt × borrow index
```

---

**Q: Why divide by the current index when borrowing?**

A new borrower must not inherit interest accumulated before the borrow.

---

**Q: Why does borrow round scaled debt up while repay rounds scaled reduction down?**

Borrow must not understate debt creation.

Repay must not remove more debt than the borrower actually paid.

---

**Q: Why is a full-repay special case needed?**

Floor rounding of scaled reduction can leave residual dust even when the borrower repays the complete quoted economic debt.

---

**Q: What does lazy accrual mean?**

The protocol stores the last committed index but calculates a current virtual index in views.

State-changing actions materialize that virtual index before mutating debt.

---

**Q: Why do we need stored utilization?**

To avoid:

```text
current index
→ current debt
→ utilization
→ rate
→ current index
```

The rate for an elapsed interval is derived from the last committed reserve state.

---

**Q: What is the difference between the interval borrow rate and current borrow rate?**

- interval rate: used to accrue time since the last committed state;
- current rate: implied by the current virtually accrued reserve state.

---

**Q: Why must borrow/repay/liquidate accrue first?**

Because each operation changes the economic state only from **now forward**.

Past interest must be applied to the old state before the mutation.

---

**Q: Can interest alone liquidate a borrower?**

Yes.

```text
debt grows
→ HF falls
```

even if collateral price and collateral amount are unchanged.

---

# 42. Explanation practice

The goal is to explain these primitives without hiding behind formulas.

## Exercise 1: explain health factor in 60 seconds

Try to explain:

1. what HF measures;
2. why LT is used instead of LTV;
3. what `HF = 1` means;
4. why debt rounding is conservative.

A good explanation should use one numeric example.

---

## Exercise 2: explain scaled debt without Solidity

Use:

```text
borrowIndex = 1.25
borrow = 1000
scaledDebt = 800
```

Then show:

```text
index → 1.40
debt → 1120
```

If the explanation requires code, simplify it further.

---

## Exercise 3: explain why "accrue before mutate"

Use three cases:

```text
borrow
repay
liquidation
```

For each, explain what would go wrong if the new state were applied before historical interest.

---

## Exercise 4: explain stored vs current utilization

Describe the circular dependency first:

```text
index needs rate
rate needs utilization
utilization needs debt
debt needs index
```

Then explain why the elapsed interval uses the last committed state.

---

## Exercise 5: explain why liquidation may worsen HF

Use an underwater example and distinguish:

```text
relative HF
vs
absolute protocol exposure
```

---

# 43. Whiteboard mental model

For architecture discussions, draw the system in three layers.

## Risk layer

```text
collateral
→ oracle value
→ LTV / LT
→ HF
→ liquidation
```

## Liquidity layer

```text
available debt token
+
total debt
→ utilization
→ interest rate
```

## Time/accounting layer

```text
stored index
+
elapsed time
+
interval rate
→ current index
→ scaled debt reconstruction
```

Then connect:

```text
current debt
→ HF
current debt
→ utilization
```

This makes the feedback loops visible.

---

# 44. Review checklist

Before changing lending debt accounting, ask:

### Units

- [ ] Is this value WAD, token native units, or scaled units?
- [ ] Are scaled and actual debt ever compared directly?
- [ ] Are quote currency and token units clearly separated?

### Risk

- [ ] Does borrow enforce LTV?
- [ ] Does withdrawal enforce resulting HF?
- [ ] Does liquidation use LT/HF rather than LTV?
- [ ] Are collateral and debt rounded conservatively?

### Interest

- [ ] Is utilization based on debt-token reserve state?
- [ ] Is the rate curve continuous at the kink?
- [ ] Is post-kink utilization normalized correctly?
- [ ] Does the elapsed interval use the intended reserve snapshot?

### Index

- [ ] Does `borrowIndex` start at `1e18`?
- [ ] Can it ever decrease?
- [ ] Does a view expose virtually accrued current debt?
- [ ] Does state mutation materialize accrual first?
- [ ] Does preview equal committed accrual?

### Scaled debt

- [ ] Borrow conversion rounds appropriately.
- [ ] Repay conversion rounds appropriately.
- [ ] Full repay clears dust.
- [ ] Zero-scaled debt reduction is rejected.
- [ ] `totalScaledDebt` tracks every user mutation.

### Liquidation

- [ ] Historical interest is accrued before liquidation mutation.
- [ ] Liquidation uses current economic debt.
- [ ] Close factor is enforced.
- [ ] Collateral seizure includes bonus.
- [ ] Seizure cannot exceed borrower collateral.
- [ ] Token-transfer failure rolls back debt and collateral accounting.

### Security

- [ ] External token interactions are reviewed for callbacks.
- [ ] Intermediate state exposed to callbacks is conservative.
- [ ] No duplicate source of truth exists for nominal and scaled debt.
- [ ] Reverts restore index, balances, and token transfers atomically.

---

# 45. What this lab still simplifies

This implementation is intentionally not a production lending market.

Important missing or simplified areas include:

- no supplier share accounting;
- no liquidity index;
- no interest-bearing deposit token;
- simplified USDC ≈ $1 assumption;
- raw pool token balance used as available liquidity;
- simple interval accrual;
- no reserve treasury accrual;
- no bad-debt resolution mechanism;
- no caps / isolation mode / eMode;
- no flash-loan integration;
- no governance-controlled risk configuration;
- no full reserve lifecycle;
- no production-grade oracle fallback architecture wired into the pool by default;
- no formal invariant/fuzz suite yet for the full indexed pool;
- no multi-reserve architecture.

These omissions are deliberate. The purpose of the milestone was to derive the mechanics before reading a production codebase.

---

# 46. Bridge to Aave-style architecture

The next useful step is to map the lab concepts to Aave V3.

Conceptually:

| Lab concept | Aave-style concept |
|---|---|
| `borrowIndex` | variable borrow index |
| `totalScaledDebt` | scaled variable debt supply |
| `_scaledDebt[user]` | user's scaled variable debt balance |
| `currentBorrowIndex()` | normalized/current debt-index view |
| `_accrueInterest()` | reserve-state/index update |
| `InterestRateModel` | interest-rate strategy |
| `utilization()` | reserve utilization inputs |

The purpose of that comparison is not to copy names.

It is to answer:

```text
Which problem does each production abstraction solve?
```

Because the primitives have now been derived manually, production code should be easier to reason about.

---

# 47. Compact interview recap

If you need to recover the milestone quickly, remember these ten points:

1. **LTV creates risk; liquidation threshold controls liquidation.**
2. **HF can fall from price movement or interest growth.**
3. **Liquidation reduces exposure but does not guarantee solvency.**
4. **Utilization measures reserve liquidity usage, not collateral risk.**
5. **Kinked rates sharply penalize liquidity scarcity.**
6. **Rates do not change debt until time is accounted for.**
7. **Per-user interest updates do not scale; a global index does.**
8. **Scaled debt stores ownership/accounting units; the index supplies time.**
9. **Accrue before borrow/repay/liquidation mutation.**
10. **Stored utilization exists to break the current-index/current-debt/rate circular dependency.**

---

# 48. Final mental model

The lending milestone can be compressed into one system:

```text
                     COLLATERAL SIDE
                     ===============

collateral amount
      ↓
oracle price
      ↓
collateral value
      ↓
 ┌─────────────┬─────────────────────┐
 │             │                     │
LTV      liquidation threshold       │
 │             │                     │
 ↓             ↓                     │
borrow cap   health factor           │
               ↓                     │
           liquidation               │
                                     │
                                     │
                     DEBT / LIQUIDITY SIDE
                     =====================

available debt-token liquidity
             +
      total scaled debt
             +
        borrow index
             ↓
        current debt
             ↓
        utilization
             ↓
      interest-rate curve
             ↓
      interval borrow rate
             ↓
         elapsed time
             ↓
        borrow index
             ↓
  scaled debt × borrow index
             ↓
      current user debt
             ├────────────→ health factor
             └────────────→ utilization
```

The protocol is therefore not a collection of independent functions.

It is a system of coupled invariants where:

```text
price
time
liquidity
interest rates
debt accounting
and liquidation risk
```

continuously influence each other.

That systems-level reasoning is the main engineering result of this milestone.
