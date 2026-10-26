# Lending Market Lifecycle, Risk, Liquidation and Operational Controls

## Purpose and scope

This guide captures the transition from lending labs to the multi-asset market under `src/lending/`: market wiring, reserve initialization, custody, supply and debt tokens, collateral selection, account data, delegated borrowing, repayment, liquidation, treasury, caps, and reserve status controls.

It complements:

- [Lending Core Primitives and Indexed Debt](lending-core-primitives-and-indexed-debt.md)
- [Lending Reserve State and Interest Accounting](lending-reserve-state-and-interest-accounting.md)
- [Production Oracle Architecture Patterns](oracle-production-architecture-patterns.md)

Those guides document earlier milestones. In particular, their aggregate positions, actual-unit treasury accrual, and old liquidity-rate formulas must not be mistaken for the current market implementation.

**Source snapshot:** `VitalR/defi-protocol-lab`, `main` at `2a25e1e929a43a92611df19a6ea99e0d5919985b`, inspected on 2026-10-26. This is an implementation and study guide, not an audit or a claim of production readiness. Tests described here were inspected or reported passing during development; no fresh Forge execution was performed while preparing this document.

Suggested repository path: `docs/guides/lending-market-lifecycle-risk-and-controls.md`.

---

## 1. The central mental model

A market combines three separate responsibilities:

1. **Reserve accounting:** cash, debt, indexes, rates and protocol income.
2. **Position ownership:** which user owns supply shares or owes debt shares.
3. **Credit risk:** which assets secure an account and whether its debt is acceptable.

The Pool coordinates them. A correct token transfer alone does not prove that a position is safe; a correct health factor alone does not prove that cash is available.

> Indexes settle elapsed time. Actions change current positions. Updated rates price the next interval.

The full mutation lifecycle is:

1. Validate arguments, reserve existence and operation availability.
2. Accrue the old interval using the stored rates.
3. Check current limits and calculate scaled amounts.
4. Apply the action and any required post-action risk validation.
5. Set rates for the next interval.

Underlying transfers occur at the appropriate point for each operation. Supply and repayment collect exact funds before crediting the corresponding position changes. Borrow and withdrawal validate the resulting position before releasing underlying. Reentrancy protection and atomic rollback are essential around these interactions.

---

## 2. Architecture and trust boundaries

| Component | Responsibility |
|---|---|
| `PoolAddressProvider` | Registry for Pool, Configurator, price oracle and treasury |
| `PoolConfigurator` | Authorized entry point for reserve administration |
| `Pool` | Operation orchestration, reserve state and collateral flags |
| `ScaledSupplyToken` | Per-reserve supplier claims and underlying custody |
| `ScaledDebtToken` | Per-reserve non-transferable debt and credit delegation |
| `AccountDataLogic` | Aggregate account valuation and risk capacities |
| `LiquidationMath` | Pure liquidation quotes with collateral limits |
| `AssetOracleRouter` | Asset configuration and valuation interface |
| `PushOracleAdapter` | Feed normalization and validity/freshness checks |

### One market does not mean one Pool per blockchain

A deployment is a market with its own registry, reserves and policies. A chain can host multiple markets with different assets, risk parameters, governance or isolation assumptions. Sharing a chain does not require sharing one credit system.

Our Pool supports multiple reserves through `mapping(asset => ReserveData)` plus an enumerable reserve list. Underlying is held by the corresponding supply token. Splitting custody by reserve improves separation, but does not remove the systemic trust in Pool logic: Pool can mint/burn positions and instruct transfers from these custody contracts.

There is no implemented `marketId` field in this version. A name or market identifier is a deployment/discovery concept unless explicitly used in contract logic; it is not a reserve or a user position.

### Provider binding

```solidity
IPoolAddressProvider public immutable override ADDRESSES_PROVIDER;
```

- The type provides typed calls to the registry.
- `public` generates the external getter required by the interface.
- `immutable` fixes this deployment's registry reference.
- `override` declares that the generated getter implements the interface function.

The provider checks registration candidates with:

```solidity
address candidateProvider = address(IPool(newPool).ADDRESSES_PROVIDER());
require(candidateProvider == address(this), ...);
```

The cast is necessary because the getter returns an interface type while `address(this)` is an address. A small shared interface such as `IProviderBound` is optional interface segregation; putting the getter directly in the relevant component interfaces is also valid. The provider itself does not need to claim that it is bound to another provider.

This check detects miswiring. It does not prove that arbitrary candidate code is safe: malicious code can return the expected address. Code-length checks likewise prove neither ERC-20 compliance nor trustworthiness.

Pool registration is one-time in this implementation. Configurator, oracle and treasury addresses are replaceable by provider administration. A registry is not a proxy upgrade mechanism.

---

## 3. Reserve data and units

`ReserveData` groups:

- `state`: indexes, cash, treasury accrual, rates, reserve factor, timestamp;
- `configuration`: LTV, liquidation threshold, bonus, caps and status flags;
- token addresses, underlying decimals and initialization status.

Grouping these fields is for responsibility and readability. Putting nested structs near the top is not an economic requirement. Storage layout must be reviewed if upgradeability is introduced; changing representation is more significant than cosmetic ordering.

| Quantity | Unit |
|---|---|
| Supply/borrow/repay/withdraw amounts, cash and caps | Underlying smallest units |
| User and total scaled balances | Underlying-denominated shares before index multiplication |
| Borrow/liquidity indexes, rates, LTV, threshold, bonus multiplier | WAD (`1e18`) |
| Account values and capacities | USD WAD |
| Oracle price | USD WAD per whole underlying token |
| `accruedToTreasuryScaled` | Pending scaled supply units |

For an amount `a`, token decimals `d`, and price `P`:

```text
valueWad = a × P / 10^d
```

Feed decimals and token decimals are independent. A USDC feed with 8 decimals represents $1 as `1e8`; the router still needs USDC token decimals `6`. WBTC token decimals `8` do not become `18` merely because prices are normalized to WAD.

The current router accepts configured token decimals and checks their supported range; it does not automatically verify equality with token metadata. Configuration correctness remains an administrative responsibility.

---

## 4. Reserve initialization and custody

An owner calls Configurator, which resolves Pool and invokes `initReserve(asset)`. Pool authorizes the current Configurator, validates the reserve, reads metadata and deploys its supply/debt tokens.

Initial state includes indexes of `WAD`, base borrow rate, zero liquidity rate, reserve factor of 10%, and the current timestamp. An initialized reserve is not automatically enabled as collateral or for borrowing; configuration establishes those policies.

All ordinary underlying movement follows:

| Action | Movement |
|---|---|
| Supply | Caller → reserve supply token |
| Borrow | Reserve supply token → caller |
| Repay | Payer → debt reserve supply token |
| Withdraw | Reserve supply token → requested recipient |
| Liquidation payment | Liquidator → debt reserve supply token |
| Liquidation underlying settlement | Collateral supply token → liquidator |

Debt tokens do not hold repayment cash. Supply-token transfers move claims without moving custody cash.

`TokenTransfer.pullExactTo` measures the recipient balance delta and rejects an unexpected received amount. Outgoing `pushExact` validates the intended spend/receipt. This deliberately rejects incompatible transfer behavior; it is not general support for fee-on-transfer, rebasing or malicious assets.

Pool cannot use `transferFrom` to spend a custody contract's funds merely because it knows that address. `transferUnderlyingTo`, restricted to Pool, lets the custody contract perform its own outgoing transfer without introducing a standing allowance from custody to Pool.

---

## 5. Scaled accounting and rounding

Let `W = 1e18`, `I_L = liquidityIndex`, and `I_B = borrowIndex`.

```text
user supply = floor(userScaledSupply × I_L / W)
user debt   = ceil(userScaledDebt × I_B / W)
```

| Action | Scaled conversion | Policy |
|---|---|---|
| Supply mint | amount × W / I_L | Floor |
| Partial withdraw burn | amount × W / I_L | Ceil |
| Borrow mint | amount × W / I_B | Ceil |
| Partial repay burn | amount × W / I_B | Floor |
| Ordinary supply transfer | amount × W / I_L | Ceil |
| Liquidation debt burn | payment × W / I_B | Floor, except full close |
| Liquidation collateral movement | quote × W / I_L | Ceil, except full close |

Rounding follows economic ownership: avoid issuing an excessive claim, understating borrowed debt, erasing unpaid debt, or releasing underlying against too little destroyed claim.

Positive actual amounts can map to zero shares. Supply rejects this through `SupplyTooSmall`; repayment rejects it through `RepayTooSmall`.

### Full closure

Conversions are not exact inverses. A full withdraw burns all of that user's remaining supply shares; a full repay burns all of that user's debt shares. This also handles the `type(uint256).max` request convention.

```solidity
withdrawn = amount == type(uint256).max ? userSupply : amount;
repaid = Math.min(amount, userDebt);
```

The event reports the actual fulfilled amount, not the original oversized request.

### Aggregate actual balances

Scaled balances sum exactly to scaled totals. Actual balances need not sum exactly to an actual total: applying Floor/Ceil separately to each user differs from rounding a single aggregate. State invariants should use scaled units for exact ownership conservation.

Token mint/burn events can report the before/after actual-balance delta, which may differ slightly from the requested underlying amount. Ordinary transfer events report their specified actual amount. Keep these semantics separate in integrations and tests.

---

## 6. Supply and withdrawal

```solidity
supply(address asset, uint256 amount, address onBehalfOf)
withdraw(address asset, uint256 amount, address to) returns (uint256 withdrawn)
```

Supply spends the caller's underlying and credits `onBehalfOf`. The underlying approval is to Pool, because Pool executes the incoming transfer. Supply does not automatically enable collateral.

Withdrawal burns the caller's supply position and sends assets to `to`. No new underlying approval is required. It checks both the user's claim and accounted available liquidity.

If the position was collateral, health is checked after the burn and any full-balance flag cleanup, before releasing underlying. Using the old balance or checking health only before mutation would permit collateral escape.

If the user has no debt, `_validateUserHealth` returns without oracle access. An ordinary withdrawal should not require fresh prices when there is no debt-based collateral requirement.

Direct donations are excluded from `availableLiquidity`. They do not mint claims or automatically alter utilization. `unaccountedCash` exposes excess custody balance. Recovery/allocation of this surplus is a separate policy, not an implied treasury entitlement.

---

## 7. Collateral flags and account data

`_usingAsCollateral[user][asset]` records explicit collateral selection. Enabling requires an initialized reserve, positive threshold and a supply position. Disabling is not prevented merely because the threshold was subsequently changed to zero.

The internal helper updates the supplied `user`, not implicitly `msg.sender`; this is necessary when Pool clears another user's flag during liquidation.

Automatic cleanup uses scaled balance exhaustion. Comparing scaled shares to actual balance is a unit error. A partial actual withdrawal can consume all shares after rounding; checking share exhaustion catches this.

### Storage parameters to libraries

`AccountDataLogic` receives mappings and an array as `storage` parameters. These are references to Pool storage, not copies. The internal library executes in the caller's context. Mapping keys cannot be enumerated, which is why the reserve list exists.

The returned `AccountData` is `memory`. It cannot be assigned to a `storage` pointer, because it is a calculated result rather than a persistent storage object.

### Calculation

For each reserve:

- Collateral counts only if the user flag is enabled, threshold is positive and supply balance is positive.
- Collateral USD valuation and weighted capacities use Floor.
- Positive debt counts regardless of collateral flag or borrowing-enabled status; debt valuation uses Ceil.
- No supply/debt netting is performed.
- Oracle prices are queried only for economically relevant positive positions.

```text
borrowCapacity      = sum(collateralValue_i × LTV_i)
liquidationCapacity = sum(collateralValue_i × threshold_i)
availableBorrows    = max(borrowCapacity − debtValue, 0)
HF                  = liquidationCapacity / debtValue
```

All ratios are appropriately scaled by WAD. No debt gives `healthFactorWad = type(uint256).max`.

At $2,000/WETH, 1 WETH collateral with LTV 75% and threshold 80% gives $1,500 borrowing capacity and $1,600 liquidation capacity. A $1,550 debt exceeds new-borrow capacity but still has HF above 1.

**LTV controls new debt. The liquidation threshold controls maintenance health.** Withdrawal, disabling collateral and supply transfer validate against liquidation capacity in this implementation.

---

## 8. Borrowing and credit delegation

```solidity
borrow(address asset, uint256 amount, address onBehalfOf)
```

The caller receives underlying. `onBehalfOf` owns the debt and supplies the collateral backing it. These can differ only with a sufficient delegation allowance on the debt token.

Example:

- Bob supplies USDC liquidity.
- Alice supplies WETH collateral.
- Alice approves Charlie to borrow on her behalf.
- Charlie calls borrow and receives USDC.
- Alice owes the debt; Bob still owns his supplier claim.

Liquidity provider, debt owner and cash recipient are independent roles.

Debt-token methods are `approveDelegation`, `borrowAllowance`, and Pool-only `mintBorrow(caller, onBehalfOf, amount, scaledAmount)`. Allowances are in underlying units. Finite allowances decrease, zero revokes, and max uint represents unlimited delegation. Ordinary ERC-20 debt transfer and allowance methods revert.

Pool accrues, validates borrowing availability/cap/cash, mints debt, calculates post-mint account data, and requires debt value not to exceed borrowing capacity before transferring underlying. A later revert restores allowance, debt and cash changes atomically.

Debt-token `mintScaled` remains Pool-only, including for fixtures. The token trusts Pool to align actual and scaled parameters; the production borrow path must use the delegation-aware method.

---

## 9. Repayment and interest over time

```solidity
repay(address asset, uint256 amount, address onBehalfOf)
    returns (uint256 repaid)
```

Repay collects the payer's debt underlying, credits reserve cash and burns the specified user's debt shares. Anyone can repay another user's debt with their own funds; credit delegation is not required.

Repay does not require borrowing to remain enabled and does not require price valuation. It does respect reserve pause under our full-pause policy.

### Canonical one-year example

Initial supply is 2,000 USDC, debt 1,000 USDC, cash 1,000 USDC. With utilization 50%, borrow APR is 4.5%, supplier APR 2.025%, and reserve factor 10%.

After one elapsed year with no intermediate accrual:

| Quantity | Value |
|---|---:|
| Borrow index | 1.045 WAD |
| Liquidity index | 1.02025 WAD |
| Debt | 1,045 USDC |
| Original supplier claim | 2,040.5 USDC |
| Newly allocated protocol interest before share conversion | 4.5 USDC |
| Cash before repayment | 1,000 USDC |

Full repay requires the interest as well as the original principal. Alice must obtain the extra 45 USDC. Cash becomes 2,045 USDC, while debt becomes zero.

Partial repay of 400 USDC burns `382,775,119` scaled debt units and leaves actual debt `645,000,001` microUSDC. The extra micro-unit illustrates conservative rounding, not an unexplained cash loss.

After a time warp, views preview current balances but `getReserveData` still returns stored indexes until accrual. A price-dependent action after a year requires fresh mock feeds. Refresh feed timestamps/prices; do not disable staleness validation to make the test pass.

---

## 10. Supply transfer finalization

Supplier claims are transferable; debt obligations are not freely transferable. This creates a collateral escape path unless supply transfers invoke risk validation.

`ScaledSupplyToken._transferActual` moves scaled shares, then calls Pool's `finalizeTransfer(asset, from, to)`. Pool verifies the calling reserve supply token, checks pause, clears an exhausted sender's flag and validates the sender's resulting health when needed.

- A recipient's collateral flag is not automatically enabled.
- Total shares and reserve cash do not change.
- An unhealthy transfer reverts all balance and allowance mutations.
- The callback is made for self-transfers and zero-transfers so pause cannot be bypassed by token early returns.
- Liquidation uses a separate Pool-only transfer path without ordinary health validation: liquidation can legitimately leave HF below 1.

At 1 WETH collateral worth $2,000 and 1,000 USDC debt, transferring 0.3 aWETH leaves liquidation capacity $1,120 and succeeds. Another 0.3 would leave capacity $640 and is rejected. If attempted through `transferFrom`, the spent allowance is restored by rollback.

---

## 11. Liquidation lifecycle and API

```solidity
liquidationCall(
    address collateralAsset,
    address debtAsset,
    address user,
    uint256 debtToCover,
    bool receiveSupplyToken
) returns (uint256 debtRepaid, uint256 collateralSeized)
```

The liquidator chooses a repayment asset and a collateral asset from the user's portfolio. Eligibility depends on **whole-account health**. Payment/seizure and the current close-factor limit are applied to the **selected debt reserve**.

Execution:

1. Validate initialized reserves and pause on both selected assets.
2. Accrue the debt reserve and, if different, collateral reserve.
3. Validate positive selected debt and eligible positive selected collateral.
4. Calculate account HF; require `HF < WAD`. Exactly 1 is not liquidatable.
5. Apply close factor and requested budget.
6. Quote payment and collateral with the collateral reserve's bonus.
7. Calculate debt and collateral shares.
8. Pull debt underlying into the debt reserve supply token; increase cash and burn debt shares.
9. Transfer collateral shares, or burn them and release underlying subject to collateral liquidity.
10. Clear exhausted collateral flag and update each affected reserve's rates once.

The current policy is 50% close factor when `0.95 < HF < 1`, otherwise 100% when `HF <= 0.95`. At the threshold itself, the maximum factor applies. These are this implementation's constants, not a claim that every Aave release or market uses identical rules.

Close factor is per call. A second invocation evaluates the remaining position again; it is not a daily or cumulative budget.

---

## 12. Liquidation quote and collateral exhaustion

`liquidationBonusWad = 1.05e18` is the complete multiplier, not the incremental 5%.

For debt amount `x`, debt price `P_D`, collateral price `P_C`:

```text
debtValue       = floor(x × P_D / 10^debtDecimals)
collateralValue = floor(debtValue × bonus / WAD)
collateralQuote = floor(collateralValue × 10^collateralDecimals / P_C)
```

If quoted collateral exceeds the user's balance, invert the valuation conservatively to obtain the supported debt amount, lower the payment and quote again. Do not charge the original full payment while merely capping the collateral output.

Example: 0.21 WETH at $1,000 with a 1.05 multiplier supports 200 USDC of repayment and 0.21 WETH seizure, even if the liquidator requested 500 USDC.

Inverse rounding can leave dust; exact collateral exhaustion is not guaranteed for arbitrary values. Zero resulting payment or collateral is rejected. The library has price/bonus/decimal guards and bounded integer arithmetic, so fuzz domains must distinguish meaningful small-amount reverts from genuine failures.

Partial debt burn uses Floor. Collateral share conversion uses Ceil; if the quote consumes the full actual balance, all user shares are taken. In the supply-token branch the actual value of transferred shares can differ slightly from the nominal quote because of rounding.

The implementation currently has no separate liquidation protocol fee. The bonus is a reward from the borrower's collateral, not newly created protocol profit.

---

## 13. Settlement modes, repeated liquidation and profitability

| Mode | Liquidator gets | Collateral reserve cash | Total collateral supply shares |
|---|---|---|---|
| `receiveSupplyToken = false` | Underlying collateral | Decreases | Decreases |
| `receiveSupplyToken = true` | Supplier shares | Unchanged | Unchanged |

Receiving supply tokens permits settlement without immediate collateral cash availability. It transfers the liquidity risk to the liquidator, who may need to wait or find a market for those claims. Preserving cash is not additional protocol profit.

Liquidator net result is collateral resale value minus payment, gas, trading fees, slippage and funding cost. Oracle-value profit is not guaranteed executable profit.

### Why liquidation can worsen HF

For one collateral, let C be its value, D debt, T threshold, B bonus multiplier and x repaid debt value:

```text
HF_before = T × C / D
HF_after  = T × (C − B × x) / (D − x)
```

For positive remaining debt, HF improves only when `HF_before > T × B`. At threshold 0.8 and bonus 1.05, the boundary is 0.84. Starting at HF 0.8, repaying $500 from $1,000 debt and seizing $525 collateral leaves C=$475, D=$500, HF=0.76.

The purpose is to recover debt and reduce exposure; restoring health is not guaranteed. Do not run ordinary withdrawal/transfer health checks after liquidation.

### Accrued-debt example

After the one-year example, set WETH to $1,200. Collateral liquidation capacity is $960; debt is $1,045; HF is below 0.95.

- First payment 500 USDC seizes 0.4375 WETH.
- Remaining debt is `545,000,001` microUSDC, collateral 0.5625 WETH, liquidation capacity $540, HF about 0.9908.
- Another payment 100 USDC seizes 0.0875 WETH.
- Remaining debt is `445,000,002` microUSDC, collateral 0.475 WETH, capacity $456, HF about 1.0247.
- A subsequent liquidation is rejected because health has been restored.

After the first call the account remains eligible, but the second call uses the 50% factor because current HF is above 0.95. Eligibility is not automatic execution: a liquidator must submit a transaction.

### Higher collateral index

Set liquidity index 1.25 before supplying 1 WETH in a test fixture. The deposit mints 0.8 scaled shares. Seizing 0.525 WETH consumes 0.42 shares, leaving 0.38 shares worth 0.475 WETH. These exact-friendly numbers test units; they do not independently exercise a fractional Ceil boundary.

---

## 14. Same-asset and reverse-asset positions

If `collateralAsset == debtAsset`, both storage references alias the same reserve. Accrue and update its rates once. Underlying settlement increases cash by repayment and decreases it by collateral payout; share settlement only adds repayment cash.

For a portfolio containing only one asset on both sides, using the same price:

```text
HF = collateralUnits × price × threshold / (debtUnits × price)
   = collateralUnits × threshold / debtUnits
```

Common price movement cancels. Interest-rate differences, parameter changes and other portfolio assets still matter. Borrowing and supplying the same asset can support external strategies or incentives, but ordinarily creates negative interest carry without an external benefit. Support for the aliased reserve path is implemented; a dedicated same-asset integration test was discussed but not established as completed in this chat.

USDC collateral / WETH debt is also meaningful. Borrowing WETH and selling it establishes short ETH exposure: rising ETH prices increase USD debt and liquidation risk. Holding the borrowed WETH retains an offsetting asset, so borrowing alone is not equivalent to a directional short. Our initial configuration does not enable this reverse market automatically; USDC collateral parameters, WETH borrowing and WETH funding must be configured.

Pool uses ERC-20 WETH. Native ETH support belongs in a separate wrapping gateway, with appropriate delegation for gateway borrowing. A mock with `mint()` alone does not test real WETH `deposit`/`withdraw` integration. Gateway implementation remains future work.

---

## 15. Treasury: pending shares become issued claims

`accruedToTreasuryScaled` intentionally names the unit. Renaming a field is not the same as changing its representation: a live system with old actual-unit values would require a migration before interpreting them as scaled amounts.

Accrual computes:

```text
interest = debtAtNewIndex − debtAtOldIndex
treasuryActual = floor(interest × reserveFactor / WAD)
treasuryScaled = floor(treasuryActual × WAD / newLiquidityIndex)
pendingScaled += treasuryScaled
```

Previously pending shares participate in future liquidity-index growth. Newly allocated shares are converted at the new index so they do not receive the elapsed interval's supplier yield retroactively.

`mintToTreasury(address[] assets)` is permissionless. It reads the configured recipient, accrues each reserve, clears its pending scaled amount, mints exactly those shares and updates rates. No underlying moves. Pending shares become issued shares; they must not remain counted in both places.

For the canonical first year:

```text
floor(4,500,000 × WAD / 1.02025e18) = 4,410,683 scaled units
floor(4,410,683 × 1.02025e18 / WAD) = 4,499,999 microUSDC
```

The conversion loses sub-unit entitlement according to the Floor policy. Treasury can withdraw its issued claims subject to ordinary cash availability. It is not automatically enabled as collateral.

### Distribution rate in this market

The current model uses effective supply claims, including pending treasury:

```text
effectiveScaledSupply = issuedScaledSupply + pendingTreasuryScaled
effectiveSupply = ceil(effectiveScaledSupply × liquidityIndex / WAD)
grossSupplyRate = floor(borrowRate × currentDebt / effectiveSupply)
liquidityRate = floor(grossSupplyRate × (WAD − reserveFactor) / WAD)
```

Zero effective supply returns zero. Borrow pricing still uses debt divided by cash plus debt. The distribution denominator is explicitly the claim population, avoiding reliance on an approximate balance-sheet identity. This is a project policy, not a byte-for-byte copy of Aave's interest strategy.

At an action's timestamp after accrual, preview indexes equal the committed indexes. A current rate quote is not the rate retroactively charged over the old interval.

### Recipient management

Treasury is mutable in `PoolAddressProvider`, not immutable in Pool. Existing issued shares remain with the old recipient; pending claims at the next mint go to the new recipient. A permissionless mint immediately before an address change may still issue to the old address. Migration policy must account for transaction ordering.

No configured treasury blocks mint, not ordinary reserve accrual or repayment. A contract-code check would not prove a recipient can control its shares; EOAs and multisigs are also valid addresses.

---

## 16. Balance sheet, rounding and bad debt

At a consistent valuation timestamp, define:

```text
accounting assets = accounted cash + aggregate borrower debt
claims = actual value of (issued supply shares + pending treasury shares)
surplus = accounting assets − claims
```

Round the combined supply-share population once when checking aggregate claims. Summing separately rounded user balances can conceal rounding differences.

The intended property for balanced, supported-asset states is that claims do not exceed assets, with conservative rounding leaving surplus. This is a property to test across sequences, not a theorem established by passing a few examples. Aggregate Ceil/Floor behavior, repeated small operations, long elapsed intervals and user-level vs aggregate debt are important counterexample domains.

Never mix current preview balances with old pending treasury and assume the result is a complete current balance sheet. Either use stored indexes/pending at the committed timestamp, or preview all relevant accrual consistently.

Stored-state backing checks do not by themselves test every uncommitted future interval. Verify preview/accrual correspondence as well. Do not add an arbitrary tolerance just to silence a failing invariant.

### Economic recoverability

At collateral exhaustion, remaining debt remains recorded in this implementation. If cash is 1,200 and debt 800 against claims 2,000, algebraic equality does not prove the 800 receivable is recoverable.

Liquidity shortage is lack of immediately usable cash. Bad debt is an impaired receivable. Deficit recognition, coverage capital and loss allocation are separate mechanisms. Removing debt without addressing outstanding claims exposes a deficit; continuing to treat unrecoverable debt as ordinary interest-bearing backing can create phantom income.

Bad-debt accounting/coverage is future work. No automatic write-off, deficit ledger, insurance or Umbrella-like coverage mechanism has been implemented. Conservative risk parameters, liquid markets, reliable oracles, caps and liquidator incentives reduce risk but cannot eliminate price gaps or market failure.

---

## 17. Supply and borrow caps

Caps are underlying amounts; zero means unlimited. They are reserve-wide, not per user, and apply in addition to health, cash and borrowing-enabled checks.

### Supply cap

After accrual:

```text
effectiveSupply = ceil((issuedShares + pendingTreasuryShares) × I_L / WAD)
require effectiveSupply <= cap
require amount <= cap − effectiveSupply
```

Short-circuiting avoids subtraction underflow when the current reserve is already over cap. Checking the deposit amount conservatively avoids using share-mint rounding to bypass the limit.

Pending treasury must count. With issued claims 2,040.5 and treasury about 4.5, a cap of 2,042 must reject an extra 1 USDC even though issued claims alone would permit it. Minting treasury only changes representation, so it does not need a fresh supply-cap admission check.

### Borrow cap

Calculate the proposed debt shares first, then:

```text
projectedDebt = ceil((existingScaledDebt + newScaledDebt) × I_B / WAD)
require projectedDebt <= cap
```

Using only `old actual debt + requested amount` can miss the effect of scaled rounding. Delegated borrowing consumes the same reserve-wide cap.

Interest may raise supply or debt above caps; admin may also lower caps below current volumes. These events do not force closure. New admissions are blocked, while repay and withdraw remain possible subject to their other checks.

Caps do not grant borrowing power: 10 WETH at $2,000 and 75% LTV supports $15,000, regardless of a $500,000 borrow cap. Borrowing reduces cash; it does not burn supplier claims.

---

## 18. Freeze and pause

Freeze stops reserve expansion. Full pause stops reserve operations under our explicit policy.

| Action | Frozen | Paused |
|---|---|---|
| Supply / borrow | Reject | Reject |
| Repay / withdraw | Allow, subject to normal checks | Reject |
| Supply transfer, including self/zero | Normal health checks | Reject |
| Collateral toggle | Normal checks | Reject |
| Liquidation | Allow | Reject if either selected reserve is paused |
| Treasury mint | Allow | Reject for a paused selected asset |
| Views | Available | Available |
| Admin configuration | Available | Available |
| Approvals / delegation approval | Available | Available |

Check pause before freeze and before accrual. A reverted transaction would roll back accrual anyway, but early checks avoid unnecessary interactions and make error precedence predictable.

The flags are independent. Unpause must not unfreeze. Pause does not stop economic time: interest accumulates over the interval and is reflected after operations resume.

This full-pause policy blocks repayment and liquidation as well as risk expansion, so it can increase borrower risk during downtime. It is an incident-response trade-off, not a universal recommendation for every oracle or liquidity problem. Pause on an unrelated portfolio reserve does not automatically remove its debt or collateral from account data.

Batch treasury mint is atomic: one paused selected reserve reverts the batch. Callers can submit a list of unpaused assets.

---

## 19. Access control and production boundaries

Current administration uses Ownable/Ownable2Step contracts and Pool's `onlyConfigurator`. Provider ownership is especially powerful because it can replace Configurator and oracle/treasury references.

A restricted guardian role was discussed but explicitly deferred. Do not describe it as implemented. A future full role model may use `AccessControlDefaultAdminRules`, distinct risk/emergency/governance powers and operation delays.

Two-step ownership transfer, delayed default-admin transfer and timelocked operation execution solve different problems. Merely adding roles does not make the protocol production-ready. Deployment key custody, recovery paths, monitoring, external dependencies and audit coverage also matter.

Our Pool and tokens are constructor-deployed and not proxy-upgradeable. Aave-inspired separation does not imply Aave-equivalent upgradeability, risk controls or economic security.

---

## 20. Development and test lessons

- Review the final source, not an obsolete pasted snippet or an earlier guide.
- Place fixtures in helpers; do not make one `test_...` invoke another as setup.
- Keep helper impersonation scoped and explicit. Avoid hidden `startPrank` ownership assumptions across nested helpers.
- `vm.prank` applies to the next non-cheatcode external call. Put it next to the intended action; an intervening view can consume it. `expectEmit` is a cheatcode and emitting a local expected event is not an external call.
- Use exact custom error encoding when it identifies the property under test. A generic revert may pass for allowance failure instead of the expected risk check.
- `expectRevert` does not produce meaningful return data to assert on afterward. Check reverted state instead.
- Memory reserve/config snapshots do not refresh themselves. Re-read after mutations when checking current storage.
- Separate feed precision, token precision and WAD normalization in fixtures.
- An index-setting harness is a test-only capability. Set an artificial liquidity index before deposit to avoid silently creating unbacked claims, or explicitly fund and document a synthetic state.
- Full closure tests should inspect scaled balances; exact-friendly WAD cases are insufficient for rounding validation.
- `Stack too deep` can be addressed with a coherent memory cache struct and quote helper. Enabling via-IR is a compiler strategy, not a substitute for understanding data flow.
- Internal storage library parameters alias state. Returned account data is memory. Use these locations intentionally.
- Error arguments should name their economic unit/object: `InvalidUnderlying(asset)` refers to the asset, not the provider.
- A code-length check is a cheap filter, not interface validation or an audit.

Current suite organization includes `Pool.t.sol`, `Pool.AccountData.t.sol`, `Pool.BorrowAndRepay.t.sol`, `Pool.Liquidation.t.sol`, `Pool.Treasury.t.sol`, `Pool.Caps.t.sol`, `Pool.ReserveStatus.t.sol`, and oracle suites under `test/unit/lending/oracles/`.

---

## 21. Next milestone: bounded fuzz and invariant testing

Status: planned and introduced in this chat; not reported complete. The inspected snapshot has no lending suite under `test/fuzz/lending` or `test/invariant/lending`.

Target scope:

1. Three fuzz scenarios: supply/full-withdraw rounding, repayment rounding at raised debt index, liquidation quote limits.
2. One handler-based campaign: two reserves, finite actor set, fixed treasury, time progression and stable fresh prices.
3. Four core invariants: exact supply shares, exact debt shares, independent cash accounting, and backing including pending treasury at a consistent timestamp.
4. Transition assertions for index monotonicity and treasury conversion.

Proposed paths are `test/fuzz/lending/Pool.Fuzz.t.sol`, `test/invariant/lending/Pool.Invariant.t.sol`, and `test/invariant/lending/handlers/PoolHandler.sol`.

Target only selected handler action selectors. Bound amounts using actual preconditions and count successful calls/skips so a campaign cannot pass by doing nothing. Use `fail_on_revert = true` for valid-action handlers; expected rejection tests must distinguish expected errors from arbitrary reverts.

Track cash independently with ghost inflows/outflows. Include treasury and all possible share recipients in the actor sum. Never compare summed rounded actual balances to aggregate totals expecting exact equality.

Do not assume global `HF >= 1`, `debt <= borrowCap`, or `supply <= supplyCap`: time and administrative changes can legitimately violate these statements. Validate admission constraints at successful action boundaries instead.

For the initial fixed-price campaign, constrain time/borrowing/withdrawal actions so they remain meaningful. Health can fall from interest alone. A blanket `try/catch` is not a valid substitute for handling that domain.

The existing `foundry.toml` already has `[invariant] runs = 256`, `depth = 64`, `fail_on_revert = true`. Confirm installed Foundry behavior before changing section names; do not add a conflicting duplicate profile just because an earlier message suggested a generic configuration.

Fuzzing is finite testing, not formal proof. A counterexample must first be classified as a protocol defect, an invalid property, an incomplete actor set, or a fixture/handler error. Preserve genuine failures as reproducible regression tests.

---

## 22. Interview questions and model answers

### Why use both indexes and scaled balances?

Scaled ownership changes on transactions; shared indexes express time-dependent growth. This avoids updating every user when interest accrues. Supply and debt indexes differ because borrowers fund supplier yield and protocol income.

### Why is approval required for supply but not withdrawal?

Supply spends the caller's underlying through Pool. Withdrawal spends custody cash through a Pool-authorized method after burning the caller's claim; it does not pull underlying from the user.

### Does getUserAccountData protect withdraw automatically?

No. It is a view. Each state-changing risk path must explicitly evaluate the resulting position. Transfer callbacks close another such path.

### Why do borrow and withdraw use different risk thresholds?

LTV controls admission of new debt. Maintenance operations use liquidation capacity so a buffer exists before liquidation. An account may exceed LTV while remaining above HF 1.

### Who provides funds in delegated borrowing?

Reserve suppliers provide liquidity. The delegate receives cash, while the delegator owns collateral and debt. Delegation authorizes debt creation, not ERC-20 spending from the supplier.

### Why does repay round down while borrow rounds up?

Borrow must not create too little obligation for the cash received. Partial repay must not erase more obligation than the payer funded. Full repayment burns all remaining user shares to remove dust.

### Why can debt grow without a transaction?

Views preview the index from stored rate and elapsed time. Storage is committed lazily on mutation. A quoted new rate does not reprice the elapsed interval.

### Why is aToken receipt useful in liquidation?

It transfers a claim rather than demanding immediate collateral cash. The liquidator accepts reserve liquidity risk. It is not guaranteed immediately redeemable.

### Must liquidation restore HF?

No. Bonus collateral removal can leave HF below 1 or worsen it. For one collateral, improvement requires pre-action HF above threshold times bonus multiplier, assuming positive remaining debt.

### Is HF exactly 1 liquidatable here?

No: the condition is strictly below WAD. At the separate close-factor threshold 0.95, however, this policy selects the maximum factor.

### Why can a second liquidation occur immediately?

Close factor is assessed per call against the remaining debt and current HF. Health restoration stops further calls; no block/day quota is implemented.

### Why cap payment when collateral is insufficient?

Charging the full budget while delivering only a capped collateral amount breaks the advertised exchange. The supported payment must be recalculated from available collateral and the bonus.

### Does cash plus recorded debt prove solvency?

No. It is an accounting relation. Unrecoverable debt is impaired backing and requires deficit recognition/coverage or loss allocation.

### Does treasury mint add liquidity?

No. It converts pending scaled claims into issued supply shares. Cash stays unchanged. Keeping both pending and issued amounts would double-count liabilities.

### Why include pending treasury in supply caps?

Those shares already represent claims. Excluding them makes admission depend on whether somebody happened to call the permissionless mint function.

### Why can debt exceed borrow cap without an exploit?

Interest can grow an existing position over the limit, or governance can lower the cap. The cap blocks new borrow admission; it does not cancel interest or force repayment.

### How do freeze and pause differ?

Freeze stops expansion while preserving exit/risk reduction. Our full pause stops the specified reserve operations, including repayment/liquidation, and therefore needs a recovery procedure. Neither removes portfolio balances or stops interest time.

### What prevents a transferFrom allowance being lost on failure?

EVM rollback restores the allowance decrement if the downstream callback reverts. The entire operation must remain atomic; the token must not swallow the callback failure.

### What does provider binding actually guarantee?

It catches incompatible market wiring. It does not prove candidate implementation integrity. Provider administration remains a major trust boundary.

### What is the correct invariant-testing claim for this project?

We are preparing a finite, scoped campaign over ownership, cash and accounting. Passing it will support those properties in that domain, not establish all-market solvency, all-asset compatibility or complete security.

---

## 23. Remaining roadmap and source references

After fuzz/invariants: deployment/client lifecycle integration; bad-debt accounting and coverage study; per-reserve interest strategies/reserve-factor updates; complete role governance; native ETH gateway; liquidator integration; pinned fork tests. Refine ordering as implementation evidence requires, rather than expanding all tracks at once.

Reference material:

- [Project source snapshot](https://github.com/VitalR/defi-protocol-lab/tree/2a25e1e929a43a92611df19a6ea99e0d5919985b/src/lending)
- [Project unit suites](https://github.com/VitalR/defi-protocol-lab/tree/2a25e1e929a43a92611df19a6ea99e0d5919985b/test/unit/lending)
- [Aave V3 core ReserveLogic](https://github.com/aave/aave-v3-core/blob/master/contracts/protocol/libraries/logic/ReserveLogic.sol) and [PoolLogic](https://github.com/aave/aave-v3-core/blob/master/contracts/protocol/libraries/logic/PoolLogic.sol): historical scaled treasury model, not our exact rate implementation.
- [Aave V3.4 changes](https://github.com/aave-dao/aave-v3-origin/blob/main/docs/3.4/Aave-v3.4-features.md): treasury became immutable in aToken implementations; do not generalize old storage-based treasury behavior to every release.
- [Aave Wrapped Token Gateway](https://www.aave.com/docs/aave-v3/smart-contracts/wrapped-token-gateway): native-token wrapping at the integration boundary.
- [OpenZeppelin access control](https://docs.openzeppelin.com/contracts/5.x/access-control): role administration and execution-delay distinctions.
- [Foundry invariant testing](https://getfoundry.sh/forge/invariant-testing): handlers, targeting and bounded campaigns.

External implementations evolve. Pin a version before adopting their APIs or policy. The current project source and explicitly stated market policy take precedence over loose Aave comparisons.
