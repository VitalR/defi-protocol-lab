# Lending Reserve State and Interest Accounting

## Purpose

This guide captures the completed **reserve-level accounting milestone** of the `defi-protocol-lab` project.

It sits after:

- fixed-point / WAD math;
- token transfer primitives;
- oracle subsystem;
- swap adapter work;
- core lending risk mechanics;
- borrow index / scaled debt;
- supplier scaled accounting;
- liquidity index;
- reserve factor / treasury accrual.

It focuses on the transition from isolated educational primitives into a **production-shaped reserve state machine**.

Recommended path:

`docs/guides/lending-reserve-state-and-interest-accounting.md`

---

# 1. Core Mental Model

A lending reserve is a dynamic balance sheet.

It combines three coupled layers:

## Borrower side

```text
scaled debt
× borrowIndex
=
current borrower debt
```

## Supplier side

```text
scaled supply
× liquidityIndex
=
current supplier claim
```

## Reserve economics

```text
available liquidity
+ borrower debt
→ utilization
→ borrow rate
→ liquidity rate
→ future index growth
```

The core lifecycle principle is:

> **Indexes settle the past; rates price the future.**

A state-changing reserve action should therefore follow:

```text
old stored reserve state
        ↓
accrue elapsed interval using OLD stored rates
        ↓
commit borrowIndex / liquidityIndex / treasury accrual
        ↓
apply current action
        ↓
reserve balances change
        ↓
recalculate utilization
        ↓
store NEW rates for the NEXT interval
```

This ordering avoids charging a new mutation for historical time and avoids circular rate/index dependencies.

---

# 2. Reserve State

The educational `ReserveStateModel` consolidates reserve-wide state that had previously been spread across several isolated learning contracts.

Conceptually:

```solidity
struct ReserveState {
    uint256 borrowIndex;
    uint256 liquidityIndex;

    uint256 totalScaledDebt;
    uint256 totalScaledSupply;

    uint256 availableLiquidity;

    uint256 accruedToTreasury;

    uint256 currentBorrowRate;
    uint256 currentLiquidityRate;

    uint256 reserveFactor;
    uint256 lastUpdateTimestamp;
}
```

## Reserve-level state vs user-level state

Reserve-level state describes market-wide economics:

```text
borrowIndex
liquidityIndex
totalScaledDebt
totalScaledSupply
availableLiquidity
rates
reserve factor
treasury accrual
timestamp
```

User-level state is intentionally not part of this milestone:

```text
_scaledDebt[user]
_scaledSupply[user]
```

That separation is important.

A production protocol eventually needs both:

```text
Reserve state
→ market-wide accounting

User positions
→ ownership of scaled debt/supply
```

The next milestone will focus on this boundary.

---

# 3. Borrow Index

`borrowIndex` is a global growth factor for borrower obligations.

```text
actualDebt
=
scaledDebt × borrowIndex
```

The stored index represents the last committed reserve state.

The preview/current index represents economic debt as of a later timestamp without mutating storage.

## Preview formula

For the lab model:

```text
growth
=
borrowIndex
× currentBorrowRate
× elapsed
/
YEAR
```

Then:

```text
newBorrowIndex
=
oldBorrowIndex + growth
```

Borrow index growth uses conservative rounding upward.

Reason:

> Do not understate borrower obligations because of integer truncation.

---

# 4. Liquidity Index

`liquidityIndex` is the supplier-side analogue of `borrowIndex`.

```text
actualSupplierClaim
=
scaledSupply × liquidityIndex
```

The supplier rate is:

```text
liquidityRate
=
borrowRate
× utilization
× (1 - reserveFactor)
```

Example:

```text
borrowRate    = 6%
utilization   = 80%
reserveFactor = 10%

gross supplier rate =
6% × 80%
= 4.8%

net liquidity rate =
4.8% × 90%
= 4.32%
```

After one year:

```text
liquidityIndex:
1.00 → 1.0432
```

A supplier with `1000` scaled units now has approximately:

```text
1000 × 1.0432
=
1043.2
```

without any user transaction.

---

# 5. Stored vs Current Views

Lazy accrual requires a strict distinction between stored and current economic state.

## Debt

```text
totalDebt()
→ totalScaledDebt × stored borrowIndex
```

```text
currentTotalDebt()
→ totalScaledDebt × previewBorrowIndex(block.timestamp)
```

After time passes without a state-changing transaction:

```text
currentTotalDebt() >= totalDebt()
```

and normally:

```text
currentTotalDebt() > totalDebt()
```

when the borrow rate is positive.

## Supply

Similarly:

```text
totalSupply()
→ totalScaledSupply × stored liquidityIndex
```

```text
currentTotalSupply()
→ totalScaledSupply × previewLiquidityIndex(block.timestamp)
```

This is one of the most important lazy-accrual concepts:

> Economic balances can change over time even while stored scaled balances remain unchanged.

---

# 6. Utilization

Reserve utilization is based on the debt asset liquidity side of the market.

```text
U
=
totalDebt
/
(availableLiquidity + totalDebt)
```

Collateral does not belong in this denominator.

Collateral is part of credit risk.

Utilization is part of reserve liquidity economics.

## Important boundaries

```text
debt = 0
→ U = 0
```

```text
availableLiquidity = 0
and debt > 0
→ U = 100%
```

---

# 7. Kinked Borrow Rate

The lab model uses:

```text
BASE_RATE           = 2%
SLOPE1              = 4%
SLOPE2              = 75%
OPTIMAL_UTILIZATION = 80%
```

Below the kink:

```text
borrowRate
=
base
+
slope1 × U / optimalU
```

Examples:

```text
U = 0%  → 2%
U = 40% → 4%
U = 80% → 6%
```

Above the kink:

```text
normalizedExcess
=
(U - optimalU)
/
(1 - optimalU)
```

Then:

```text
borrowRate
=
base
+
slope1
+
slope2 × normalizedExcess
```

At `U = 100%`:

```text
borrowRate
=
2% + 4% + 75%
=
81%
```

With a 10% reserve factor:

```text
liquidityRate
=
81% × 100% × 90%
=
72.9%
```

This sharp post-kink increase is a liquidity pressure mechanism.

---

# 8. Reserve Accrual

The reserve accrual operation settles the elapsed interval.

Conceptually:

```text
old borrowIndex
old liquidityIndex
old stored rates
old timestamp
        ↓
preview new indexes
        ↓
calculate borrower-interest delta
        ↓
calculate treasury share
        ↓
commit both indexes
        ↓
commit treasury accrual
        ↓
commit timestamp
```

## Borrow interest should come from index delta

Prefer deriving generated borrower interest from the same accounting source of truth:

```text
debtBefore
=
totalScaledDebt × oldBorrowIndex
```

```text
debtAfter
=
totalScaledDebt × newBorrowIndex
```

```text
borrowInterest
=
debtAfter - debtBefore
```

This is better than maintaining a parallel independent interest formula.

---

# 9. Treasury / Reserve Factor

The reserve factor is the protocol share of borrower-generated interest.

```text
treasuryAccrual
=
borrowInterestGenerated × reserveFactor
```

Example:

```text
borrow interest = 480 USDC
reserve factor  = 10%

treasury accrual = 48 USDC
```

Supplier interest:

```text
432 USDC
```

So:

```text
480
=
432
+
48
```

The treasury share is not:

- 10 percentage points subtracted from APR;
- 10% of total supplied capital;
- a direct deduction from idle liquidity.

It is a share of generated borrower interest.

---

# 10. Reserve Balance Sheet

Canonical example:

```text
Initial:
supplied   = 10,000
borrowed   = 8,000
available  = 2,000
U          = 80%
borrow APR = 6%
liquidity APR = 4.32%
```

After one year:

```text
borrower debt:
8,000 → 8,480

supplier claims:
10,000 → 10,432

treasury claim:
0 → 48
```

Balance sheet:

```text
Assets:
available liquidity     2,000
borrower debt           8,480
                       ------
                       10,480

Claims:
supplier claims        10,432
treasury claim             48
                       ------
                       10,480
```

Canonical invariant:

```text
availableLiquidity + totalDebt
≈
totalSupply + accruedToTreasury
```

For exact-friendly values the equality can be exact.

For arbitrary integer states, conservative rounding may create bounded reserve surplus/dust.

A stronger general property is:

```text
availableLiquidity + totalDebt
>=
totalSupply + accruedToTreasury
```

assuming the reserve began balanced and only valid lifecycle actions occurred.

---

# 11. Action Lifecycle

All core reserve actions follow the same high-level sequence:

```text
accrue old interval
→ mutate present state
→ recalculate utilization
→ store rates for future
```

## Borrow

```text
_accrueReserve()
→ validate available liquidity
→ actual borrow → scaled debt mint
→ available liquidity decreases
→ total scaled debt increases
→ update rates
```

## Repay

```text
_accrueReserve()
→ validate repayment <= current debt
→ actual repay → scaled debt burn
→ available liquidity increases
→ total scaled debt decreases
→ update rates
```

## Supply

```text
_accrueReserve()
→ actual supply → scaled supply mint
→ available liquidity increases
→ total scaled supply increases
→ update rates
```

## Withdraw

```text
_accrueReserve()
→ validate supplier claim
→ validate available liquidity
→ actual withdrawal → scaled supply burn
→ available liquidity decreases
→ total scaled supply decreases
→ update rates
```

---

# 12. Rounding Policy

Rounding direction is part of protocol economics.

The lab follows a conservative rule:

> Do not round in a direction that gives the initiating user more economic value than they contributed, repaid, or are entitled to.

| Action | Conversion | Rounding |
|---|---|---|
| Borrow | actual → scaled debt mint | **Ceil** |
| Repay | actual → scaled debt burn | **Floor** |
| Supply | actual → scaled supply mint | **Floor** |
| Withdraw | actual → scaled supply burn | **Ceil** |

## Why borrow rounds up

Do not under-create debt for assets borrowed.

## Why repay rounds down

Do not remove more debt than the borrower actually repaid.

## Why supply rounds down

Do not create supplier claim greater than assets supplied.

## Why withdraw rounds up

Do not release more underlying than the claim that was destroyed.

---

# 13. Tiny-Amount Guards

Rounding can make a positive actual amount map to zero scaled units.

## Supply

Because supply mint rounds down:

```text
amount > 0
but
scaledMint == 0
```

must revert.

Otherwise the reserve could accept value without creating a supplier claim.

## Repay

Because partial repay burns scaled debt with Floor:

```text
amount > 0
but
scaledRepay == 0
```

must revert.

Otherwise the reserve could accept repayment while debt accounting remains unchanged.

Relevant guards:

```text
SupplyTooSmall
DebtReductionTooSmall
```

---

# 14. Full Repay and Full Withdraw

Integer conversions are not guaranteed to be exact inverses:

```text
scaled → actual → scaled
```

may differ because of rounding.

Therefore full-position closure needs a special case.

## Full repay

In the aggregate educational model:

```text
if amount == current full debt:
    totalScaledDebt = 0
```

## Full withdraw

```text
if amount == current full supply:
    totalScaledSupply = 0
```

In a real multi-user protocol, this logic operates on the user's scaled position and subtracts the corresponding user balance from the reserve total.

---

# 15. Available Liquidity vs Supplier Claim

A supplier claim is not the same as currently withdrawable liquidity.

Example:

```text
supplier claim       = 10,000
available liquidity  = 1,500
borrower debt        = 8,500
```

The supplier may have a valid economic claim of `10,000`, but cannot immediately withdraw more than the `1,500` currently available.

Therefore withdraw must validate both:

```text
amount <= supplier claim
```

and:

```text
amount <= availableLiquidity
```

This distinction is fundamental to lending protocols.

---

# 16. Rate Feedback Examples

## Borrow

Borrowing:

```text
available liquidity ↓
debt ↑
utilization ↑
borrow rate ↑
liquidity rate ↑
```

## Repay

Repayment:

```text
available liquidity ↑
debt ↓
utilization ↓
borrow rate ↓
liquidity rate ↓
```

## Supply

Supplying:

```text
available liquidity ↑
utilization ↓
borrow rate ↓
liquidity rate ↓
```

## Withdraw

Withdrawing:

```text
available liquidity ↓
utilization ↑
borrow rate ↑
liquidity rate ↑
```

Time alone can also change reserve economics:

```text
time
→ borrower debt grows
→ utilization grows
→ future borrow rate can increase
```

---

# 17. Stored Rates vs Current Calculated Rates

The reserve stores:

```text
currentBorrowRate
currentLiquidityRate
```

These rates price the interval beginning after the last committed state transition.

When the next state-changing action occurs:

```text
stored rates
× elapsed time
→ accrue indexes
```

Only after accrual and the new mutation do we recompute rates.

This avoids the circular dependency:

```text
current debt
→ utilization
→ rate
→ current debt
```

Instead:

```text
stored rate
→ accrue past
→ mutate
→ new utilization
→ new rate
```

---

# 18. Important Tests / Invariants

The milestone test suite covers:

- constructor state;
- one-interval reserve accrual;
- zero-rate interval still commits timestamp;
- borrow lifecycle;
- second interval uses post-borrow rate;
- partial repay;
- stored debt vs current debt;
- full repay;
- supply lifecycle;
- new supply does not receive historical yield;
- withdraw lifecycle;
- utilization reaching 100%;
- full supplier-position withdrawal;
- balance-sheet equality in canonical scenario;
- zero-amount guards;
- insufficient-liquidity guards;
- repay greater than debt;
- withdraw greater than supply;
- tiny supply;
- tiny debt reduction;
- invalid preview timestamps;
- index monotonicity fuzz coverage.

Core invariants to retain:

```text
borrowIndex never decreases

liquidityIndex never decreases

currentTotalDebt >= totalDebt

currentTotalSupply >= totalSupply

0 <= utilization <= WAD

debt == 0
→ utilization == 0

availableLiquidity == 0 && debt > 0
→ utilization == WAD
```

And reserve solvency/accounting:

```text
availableLiquidity + totalDebt
>=
totalSupply + accruedToTreasury
```

for a balanced reserve under valid lifecycle actions, modulo bounded rounding effects.

---

# 19. Security / Correctness Lessons

## Accrue before mutate

A new borrow must not inherit historical interest.

A new supply must not inherit historical supplier yield.

A repayment must settle historical borrower interest first.

A withdrawal must settle supplier accrual first.

## Rate update after mutate

Rates must describe the future interval, not retroactively price the past.

## Conservative rounding

Rounding must be chosen according to economic ownership and who benefits from dust.

## No silent zero-accounting transitions

Never accept economic value if the corresponding scaled accounting would remain unchanged.

## Physical liquidity is not economic ownership

`availableLiquidity`, token custody, supplier claims, debt, and treasury claims are related but distinct accounting concepts.

---

# 20. Deliberate Lab Simplifications

This milestone is intentionally not a production lending protocol.

## Aggregate positions only

The model stores:

```text
totalScaledDebt
totalScaledSupply
```

but not:

```text
_scaledDebt[user]
_scaledSupply[user]
```

Therefore full repay / full withdraw special cases currently operate on aggregate positions.

The next milestone will introduce user ownership.

## No token custody

`availableLiquidity` is accounting state, not actual ERC20 balance management.

This isolates reserve economics from transfer/callback complexity.

## Public setup helpers

Functions such as reserve setters are lab-only test hooks.

They can create economically impossible states and are not production APIs.

## WAD precision

The model uses WAD (`1e18`) rather than Aave-style RAY (`1e27`).

This is sufficient for the curriculum and keeps math transparent.

## Linear accrual per interval

Index growth is linear inside an accrual interval.

Sequential committed intervals compound because each interval starts from the previous index.

## No multi-asset / collateral risk here

The reserve model focuses on debt-asset reserve economics.

Collateral, health factor, liquidation, and oracle logic remain separate concerns already explored in earlier milestones.

---

# 21. Mapping to Aave V3

The model now maps naturally to Aave-style abstractions.

| Lab | Aave V3 concept |
|---|---|
| `borrowIndex` | variable borrow index |
| `liquidityIndex` | liquidity index |
| `totalScaledDebt` | scaled variable debt supply |
| `totalScaledSupply` | scaled supplier/aToken supply |
| `_accrueReserve()` | reserve state/index update |
| `currentBorrowRate` | current variable borrow rate |
| `currentLiquidityRate` | current liquidity rate |
| `reserveFactor` | reserve factor |
| `accruedToTreasury` | treasury accrual |
| `availableLiquidity` | reserve liquidity/accounting input |
| kinked `borrowRate()` | interest-rate strategy |

The biggest architectural difference remaining is **ownership of the scaled positions**.

Aave does not store all user debt/supply directly as aggregate reserve variables.

It separates:

```text
Reserve
→ market-wide indexes/rates/configuration

aToken
→ supplier scaled positions

VariableDebtToken
→ borrower scaled positions

Pool
→ orchestration
```

---

# 22. Next Milestone

The next milestone is:

## User Position Accounting and Tokenization Boundary

Core questions:

```text
Who owns totalScaledSupply?

Who owns totalScaledDebt?

How do user-level balances sum to reserve totals?

Why separate user balances from reserve state?

Why tokenize supplier positions?

Why tokenize debt positions?

Why are debt tokens generally non-transferable?

How does scaled mint/burn interact with reserve indexes?

How does full repay work with multiple borrowers?

How does full withdraw work with multiple suppliers?
```

Expected progression:

```text
Reserve totals
        ↓
user scaled balances
        ↓
multi-user invariants
        ↓
position ownership
        ↓
tokenization boundary
        ↓
aToken / VariableDebtToken rationale
        ↓
deeper Aave V3 mapping
```

Do not copy Aave source code directly.

The objective is to derive each abstraction from accounting and protocol requirements already learned in the lab.

---

# 23. Senior / Interview Questions

Be able to explain:

1. Why use scaled balances at all?
2. Why maintain both `borrowIndex` and `liquidityIndex`?
3. What is the difference between stored and current debt?
4. Why must reserve accrual happen before mutation?
5. Why are rates recomputed after mutation?
6. What circular dependency do stored rates avoid?
7. Why does supplier APR depend on utilization?
8. What exactly does reserve factor represent?
9. Why is `availableLiquidity` not equal to supplier claims?
10. Why can utilization increase with no user transaction?
11. Why borrow conversion rounds up?
12. Why repay conversion rounds down?
13. Why supply conversion rounds down?
14. Why withdraw conversion rounds up?
15. Why are full repay / full withdraw special cases?
16. Why must tiny repay/supply conversions revert?
17. What does the reserve balance sheet represent?
18. What is the difference between reserve state and user position state?
19. Why would a production protocol tokenize positions?
20. How does this model map to Aave V3?

---

# 24. Explanation Practice

Useful articulation drills:

## 30 seconds

Explain:

> Why do indexes settle the past while rates price the future?

## 60 seconds

Explain:

> How can borrower debt and supplier claims grow without updating every user?

## Senior interview

Explain:

> Walk through a borrow transaction after one year of inactivity, including index accrual, treasury accounting, scaled debt mint, utilization change, and rate repricing.

## Architecture review

Explain:

> Which state belongs to the reserve and which state belongs to users, and why should those responsibilities be separated?

---

# 25. Final Mental Model

The completed reserve milestone can be summarized as:

```text
                    TIME
                     │
                     ▼
            stored interval rates
                     │
                     ▼
        ┌─────────────────────────┐
        │      accrueReserve      │
        │                         │
        │ borrowIndex ↑           │
        │ liquidityIndex ↑        │
        │ treasury accrues        │
        └────────────┬────────────┘
                     │
                     ▼
               CURRENT STATE
                     │
             user action occurs
                     │
         ┌───────────┼───────────┐
         ▼           ▼           ▼
       debt      available     supply
      changes     changes      changes
         └───────────┼───────────┘
                     ▼
                utilization
                     │
                     ▼
                 new rates
                     │
                     ▼
              NEXT INTERVAL
```

The reserve is no longer just a set of lending functions.

It is a **time-evolving balance sheet with indexed claims, explicit protocol revenue, conservative rounding, and rate feedback**.

That is the key result of this milestone.
