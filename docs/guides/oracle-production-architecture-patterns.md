# Production Oracle Architecture Patterns

## Purpose

This note closes the `defi-protocol-lab` Oracle epic at the architecture level.

The goal is not to implement every possible oracle design. The goal is to be able to:

- recognize the main production oracle patterns;
- understand their trust and availability trade-offs;
- choose a reasonable design for a DeFi product;
- explain why a protocol should fail closed, fall back, pause selected actions, or aggregate sources;
- discuss the topic confidently in architecture reviews and senior Solidity interviews.

The lab implementation used throughout the epic is:

```text
PushOracleAdapter ───────────────┐
                                 │ primary
                                 ▼
                          OracleDeviationGuard
                                 ▲
                                 │ reference
UniswapV3TwapOracleAdapter ──────┘
```

Current semantics:

```text
primary price   = authoritative price
reference price = independent sanity check
deviation guard = circuit breaker

either source invalid/stale/reverting -> revert
deviation above threshold             -> revert
accepted result                        -> primary price
result timestamp                       -> oldest source timestamp
```

This is a valid **fail-closed validation oracle**, but it is only one production architecture.

---

# 1. First principle: price integrity vs availability

Oracle architecture is fundamentally a trade-off between:

```text
PRICE INTEGRITY
    Do not allow economically unsafe actions using a bad price.

vs.

AVAILABILITY
    Do not unnecessarily freeze protocol functionality.
```

There is no universally correct response to an oracle failure.

For a lending protocol, allowing a bad price can cause:

- incorrect borrowing power;
- bad debt;
- wrongful liquidations;
- failure to liquidate insolvent accounts.

For other actions, temporary unavailability may be acceptable.

Therefore production systems often separate actions:

```text
oracle unhealthy

new borrow       -> disabled
new leverage     -> disabled
liquidation      -> possibly delayed / restricted
repayment        -> allowed
collateral add   -> allowed
withdrawal       -> depends on resulting solvency
```

This is often safer than treating an oracle error as either:

```text
everything works
```

or:

```text
everything stops
```

---

# 2. Pattern: single authoritative oracle

## Model

```text
Chainlink / other trusted feed
        ↓
Oracle Adapter
        ↓
Protocol
```

This is simpler than many engineers initially expect.

A protocol does **not** automatically need multiple feeds for every asset.

### Example

Compound III documents asset prices as coming from configured Chainlink Price Feeds. Governance/configuration determines which feed an asset uses.

### Advantages

- simple;
- low gas;
- small attack surface;
- easy auditing;
- clear trust assumptions.

### Risks

The protocol inherits the source's:

- liveness;
- correctness;
- update policy;
- decentralization assumptions.

### Production lesson

More oracle sources do not automatically mean more security.

A poorly designed fallback or aggregation system can introduce more failure modes than a well-understood primary source.

---

# 3. Pattern: primary oracle + deviation guard

This is the pattern implemented in the lab.

```text
Primary
   │
   ├──────────────┐
   │              │
   ▼              ▼
 Protocol    Reference oracle
   ▲              │
   └──── Guard ───┘
```

Conceptually:

```text
abs(primary - reference) / reference <= maxDeviation
```

If valid:

```text
return primary
```

The reference is **not** necessarily part of price discovery. It is a circuit breaker.

## Good use cases

- Chainlink primary + DEX TWAP sanity check;
- issuer/reference NAV + market price sanity check;
- stablecoin oracle + secondary peg reference.

## Strength

Two sources usually fail differently.

Example:

```text
Push oracle:
resistant to instantaneous DEX manipulation

DEX TWAP:
independent on-chain market observation
```

Their diversity is more important than merely having "two feeds".

## Important limitation

If either source is mandatory:

```text
primary fails   -> revert
reference fails -> revert
```

availability becomes:

```text
availability ≈ primary availability AND reference availability
```

Therefore a deviation guard can make the total oracle **less available** than either source individually.

That is not necessarily wrong. It is a deliberate integrity-first choice.

---

# 4. Pattern: controlled fallback hierarchy

## Model

```text
Primary
   │
 healthy?
   │
 yes ───────────────> use primary
   │
 no
   ▼
Fallback
   │
 healthy?
   │
 yes ───────────────> use fallback
   │
 no
   ▼
revert / pause
```

This is substantially more dangerous than it looks.

A safe fallback system must define:

- exactly which primary failures activate fallback;
- fallback freshness requirements;
- whether deviation matters during failover;
- whether fallback may be manipulated specifically to trigger failover;
- when and how the protocol returns to primary;
- whether switching sources creates discontinuous prices;
- whether governance can force a source;
- what consumers may do during fallback mode.

## Bad implementation

```solidity
try primary.latestPrice() returns (...) {
    return primary;
} catch {
    return fallback.latestPrice();
}
```

This treats every revert as equivalent and silently changes the protocol's trust model.

## Better mental model

Fallback is a **state transition in oracle trust**, not just exception handling.

Useful state may be:

```text
PRIMARY
FALLBACK
PAUSED
```

and transitions should be explicit.

---

# 5. Pattern: median oracle

## Model

Sources:

```text
100
101
102
500
```

Mean:

```text
200.75
```

Median:

```text
101.5
```

Median aggregation is resistant to outliers as long as enough sources remain honest.

This pattern is particularly important when the protocol itself receives reports from multiple oracle providers.

Maker/Sky's oracle architecture historically includes a `Median` component where whitelisted feed providers submit prices and a valid median price is exposed.

## Security intuition

With:

```text
N independent reporters
```

an attacker generally needs to compromise enough reporters to move the median across the center of the set.

## Requirements

Median aggregation does **not** solve:

- correlated sources;
- all reporters using the same exchange/API;
- stale values;
- compromised governance;
- economic incentives of reporters.

"Five reporters" is not equivalent to five independent trust domains.

---

# 6. Pattern: N-of-M quorum / aggregation

Related to medianization but conceptually broader.

```text
M configured sources/reporters
N required valid observations
```

Example:

```text
5 reporters configured
3 valid reports required
```

Then the aggregator may use:

- median;
- mean;
- bounded mean;
- another consensus rule.

## Why use it

It reduces dependency on one reporter's liveness.

```text
one source down
≠
whole oracle down
```

## Core question

What does "valid report" mean?

Usually some combination of:

- authorized reporter;
- correct asset;
- valid signature;
- recent timestamp;
- correct round/nonce;
- bounded value;
- quorum.

This architecture is more common inside decentralized oracle networks or custom institutional oracle systems than inside a normal DeFi application's adapter layer.

---

# 7. Pattern: Oracle Security Module / delayed oracle

Sometimes immediate price updates are themselves undesirable.

A delayed oracle can expose:

```text
current price
next price
```

with a delay before `next` becomes active.

Maker/Sky's Oracle Security Module (OSM) is the classic mental model:

```text
new oracle price
      ↓
 waiting period
      ↓
 active protocol price
```

## Why delay?

It creates time for:

- governance;
- keepers;
- users;
- emergency mechanisms

to react to suspicious oracle updates.

## Trade-off

You intentionally accept stale-by-design prices.

Therefore this architecture fits protocols whose economic mechanisms are designed around the delay.

It should not be copied blindly into a system requiring near-real-time pricing.

---

# 8. Pattern: sequencer uptime sentinel

This is especially important on optimistic/rollup L2s.

Problem:

```text
oracle feed itself may be valid
but
L2 sequencer was unavailable
```

After sequencer recovery, users may not have had a fair opportunity to:

- repay;
- add collateral;
- rebalance.

Aave V3 includes a Price Oracle Sentinel concept for L2s. It can restrict borrowing/liquidations around sequencer downtime and recovery rather than pretending that price validity alone captures system health.

## Key lesson

```text
oracle health != only price-feed health
```

The execution environment can be another dependency.

For L2 lending protocols this is one of the first production oracle controls to evaluate.

---

# 9. Pattern: governance-configurable oracle sources

This is extremely common.

Conceptually:

```solidity
asset -> priceFeed
```

Governance or an authorized risk/configuration role can replace the source.

Compound documentation exposes configuration for setting protocol price feeds.

## Why necessary?

External feeds change:

- provider;
- contract;
- market;
- denomination;
- supported chain;
- migration version.

Hard-coding every feed permanently can make incidents harder to recover from.

## Security requirement

Oracle configuration is economically critical governance.

Changing:

```text
ETH/USD oracle
```

can alter:

- collateral values;
- borrow capacity;
- liquidation eligibility;
- protocol solvency.

Therefore updates typically need controls such as:

- governance;
- timelock;
- multisig;
- role separation;
- deployment/config validation;
- monitoring.

---

# 10. Pattern: emergency oracle / emergency pause

Emergency oracle mechanisms are useful when normal price infrastructure becomes unsafe.

Possible designs:

```text
A. switch to predefined emergency source
B. freeze the last trusted price
C. pause price-sensitive actions
D. manually publish bounded emergency price
```

These have very different trust assumptions.

## Freeze-last-price

Can be safer than bad data temporarily, but dangerous over long periods.

## Manual emergency price

Can restore availability, but introduces privileged price-setting power.

## Pause

Often the simplest emergency mechanism if business requirements allow it.

### Production principle

Prefer narrowly disabling economically dangerous actions instead of giving an emergency actor unrestricted ability to invent prices.

---

# 11. Pattern: MultiOracleRouter

A router does not necessarily aggregate multiple sources.

Often it simply maps:

```text
WETH -> WETH/USD adapter
WBTC -> WBTC/USD adapter
USDC -> USDC/USD adapter
```

The adapter behind each asset may itself use:

- single source;
- deviation guard;
- median;
- composite rate;
- fixed price.

This separation is valuable:

```text
routing policy
!=
price-source policy
```

A router is common once a protocol supports multiple assets, but it should remain thin.

---

# 12. Pattern: weighted prices

Weighted aggregation can mean:

```text
price =
    sourceA * weightA +
    sourceB * weightB +
    ...
```

or DEX-specific weighted tick aggregation.

Uniswap V3's `OracleLibrary` includes a weighted arithmetic mean tick utility; because ticks are logarithmic prices, a weighted arithmetic mean tick corresponds to a weighted geometric mean price.

## When useful

- combining several DEX pools;
- liquidity-weighted market observations;
- specialized index calculations.

## Main risk

Weights become part of the security model.

If weights depend on manipulable liquidity, an attacker may influence both:

```text
price
and
weight
```

This is much more specialized than a simple primary/reference guard.

---

# 13. Pattern: dynamic deviation threshold

Instead of:

```text
maxDeviation = fixed 5%
```

a protocol may adapt thresholds based on:

- market volatility;
- asset class;
- liquidity;
- oracle mode;
- time since update;
- risk state.

Example:

```text
normal market:
2%

high-volatility mode:
5%
```

## Benefit

Fewer false positives.

## Risk

More state and more parameters create:

- governance risk;
- implementation complexity;
- potentially exploitable threshold transitions.

For most applications, start with a carefully selected static threshold unless dynamic behavior solves a demonstrated problem.

---

# 14. Pattern: cross-chain oracle

A cross-chain oracle transports or reconstructs authoritative information from another chain.

Example use cases:

- L1 price/state consumed on L2;
- exchange rates;
- protocol accounting state;
- rate parameters.

Sky publishes a cross-chain SSR oracle design where state is transported across supported chains, with application-level sanity checks around received data.

## Additional trust assumptions

Now security includes:

```text
source oracle/state
+
bridge / messaging layer
+
destination receiver
+
ordering/replay validation
```

This means a cross-chain oracle is not simply "the same oracle on another chain".

---

# 15. Which patterns should a DeFi engineer know first?

Practical priority:

## Tier 1 — should know well

### 1. Single configured feed

```text
external feed -> adapter -> protocol
```

### 2. Primary + deviation guard

```text
primary + independent market reference
```

### 3. Governance-configurable sources

```text
asset -> replaceable oracle adapter
```

### 4. Fail-closed vs fallback semantics

You must be able to justify which actions stop and why.

### 5. L2 sequencer sentinel

For L2 lending/leverage protocols.

---

## Tier 2 — should be comfortable discussing

### 6. Median / quorum oracle

Important for decentralized/custom oracle systems.

### 7. Controlled fallback hierarchy

Useful but easy to design incorrectly.

### 8. Emergency oracle / circuit breaker

Critical incident-response concept.

### 9. Delayed oracle / OSM

Important architectural pattern, especially historically in Maker/Sky-style systems.

---

## Tier 3 — recognize and evaluate when required

### 10. Weighted multi-source pricing

### 11. Dynamic deviations

### 12. Cross-chain oracle transport

These are important in the right product, but not default requirements.

---

# 16. Production decision framework

When designing an oracle, ask in this order.

## A. What economic action consumes the price?

```text
display only?
mint?
borrow?
liquidate?
redeem?
settle derivatives?
```

The required security differs drastically.

## B. What is the authoritative price definition?

Examples:

```text
ETH/USD market price
stablecoin redemption value
NAV
DEX execution price
protocol exchange rate
```

Do not choose the oracle before defining the economic quantity.

## C. What source failures matter?

```text
stale
zero
negative
future timestamp
source revert
sequencer down
DEX manipulation
reporter compromise
bridge compromise
```

## D. Should failure mean:

```text
revert?
fallback?
pause selected actions?
use last good price?
manual intervention?
```

## E. Are the sources genuinely independent?

Two adapters are not independent if both ultimately depend on:

```text
same provider
same exchange
same bridge
same admin
same underlying market
```

## F. Who can change the oracle configuration?

Treat this role as a high-impact protocol risk role.

---

# 17. Production variants worth proposing

## Variant A — simple lending / vault

```text
Chainlink-style feed
      ↓
validated adapter
      ↓
protocol
```

Add:

- staleness;
- positive price validation;
- decimal normalization;
- governance-controlled feed replacement.

Good default when a mature feed exists.

---

## Variant B — stronger market sanity check

```text
Push primary
        \
         DeviationGuard -> protocol
        /
DEX TWAP reference
```

Behavior:

```text
both healthy + deviation acceptable -> primary
otherwise                           -> pause/revert
```

Good when price integrity is more important than oracle availability.

This is the lab design.

---

## Variant C — resilient fallback system

```text
Primary
   ↓ unhealthy
Fallback
   ↓ unhealthy
Pause
```

Must have explicit:

```text
source states
activation conditions
freshness
recovery policy
monitoring
events
governance controls
```

Do not implement this as a generic `try/catch`.

---

## Variant D — decentralized reporter oracle

```text
Reporter A ─┐
Reporter B ─┤
Reporter C ─┼─> quorum -> median -> validated price
Reporter D ─┤
Reporter E ─┘
```

Good when the project itself owns the oracle network / reporting process.

Much larger security and operational scope.

---

## Variant E — L2 lending

```text
Price Feed
    +
Sequencer Uptime Feed
        ↓
Oracle/Sentinel policy
        ↓
Borrow / Liquidation permissions
```

Do not interpret sequencer status as another numerical price.

It is a system-health signal.

---

# 18. Important anti-patterns

## Blind fallback

```solidity
catch {
    return fallbackPrice;
}
```

Problem: changes trust assumptions for every possible error.

## Blind averaging

```text
Chainlink = 100
Manipulated DEX = 200

average = 150
```

The attacker has still moved the protocol price substantially.

## Too many correlated sources

```text
API A
API B
API C
```

may all source the same exchange.

## Ignoring oracle mode

Consumers should know whether they are operating in:

```text
normal
fallback
emergency
```

if behavior differs.

## Governance without delay/control

Changing an oracle is often equivalent to changing protocol solvency assumptions.

## Treating a TWAP as manipulation-proof

A TWAP increases attack cost; it does not make manipulation impossible.

Security depends on:

- observation window;
- pool liquidity;
- market structure;
- attacker capital;
- economic value that can be extracted from the consuming protocol.

---

# 19. Interview questions

## What is the difference between a fallback oracle and a reference oracle?

A **reference oracle** validates another source but does not normally become the returned price.

A **fallback oracle** becomes authoritative when the primary is considered unavailable or invalid.

---

## Why can adding a secondary oracle reduce availability?

If both sources are mandatory:

```text
system healthy =
primary healthy AND reference healthy
```

Failure of either blocks the composed oracle.

---

## Why not simply average Chainlink and Uniswap?

Because averaging does not distinguish a correct source from a manipulated source.

A compromised source can still significantly shift the result.

A deviation check can instead refuse to produce a price when the sources disagree beyond an accepted bound.

---

## Why use a median?

A median reduces the influence of extreme outliers when enough independent reporters are present.

Its safety depends on reporter independence and the number of compromised reporters required to control the middle observation.

---

## What should happen when an oracle becomes stale?

There is no universal answer.

Possible policies:

```text
revert
fallback
pause selected risk-increasing operations
use a bounded last-good-price mechanism
emergency governance action
```

The correct choice depends on the protocol's economic risks.

---

## What is an L2 sequencer uptime feed used for?

It is a system-health signal.

After sequencer downtime, users may not have had a fair ability to adjust positions. Protocols such as Aave use sequencer-aware sentinel logic to restrict certain actions around downtime/recovery.

---

## Why return the oldest timestamp from a composed oracle?

If a result depends on multiple sources, it is only as fresh as the oldest required source.

```text
effectiveUpdatedAt = min(sourceUpdatedAts)
```

is conservative.

---

## Is a DEX TWAP safe from flash-loan manipulation?

A zero-duration same-block manipulation has little/no time weight, but sustained manipulation across the observation window can still affect the TWAP.

The relevant question is the cost of maintaining manipulation versus the economic value extractable from the consuming protocol.

---

## What is the biggest danger in fallback logic?

Fallback activation itself becomes an attack surface.

An attacker may try to:

- make the primary appear unhealthy;
- manipulate the fallback;
- exploit price discontinuity during source switching.

Therefore fallback conditions and recovery rules must be explicit.

---

## What is the difference between an oracle router and oracle aggregator?

A router selects the configured oracle for an asset.

An aggregator combines multiple observations into one price.

They solve different problems and should usually remain separate abstractions.

---

# 20. Final mental model

Do not start architecture with:

```text
How many oracle sources should we use?
```

Start with:

```text
What economic truth does the protocol need?

What can make that truth unavailable or incorrect?

What should each protocol action do in each failure mode?
```

Then choose the smallest architecture that satisfies those requirements.

A useful progression is:

```text
single validated source
        ↓
governance-configurable adapter
        ↓
optional independent sanity check
        ↓
action-specific circuit breaker
        ↓
fallback / median / quorum only if required
```

This avoids building an unnecessarily complex oracle subsystem while still giving a clear path to production hardening.

---

# Reference implementations / systems studied

- Uniswap V3 `OracleLibrary`: TWAP consultation, quote-at-tick precision branches, weighted arithmetic mean ticks.
- Compound III: configured Chainlink price feeds and governance-managed feed configuration.
- Aave V3: Price Oracle Sentinel / L2 sequencer uptime handling.
- Maker/Sky: Median oracle and Oracle Security Module concepts.
- Sky cross-chain SSR oracle: cross-chain oracle transport with destination-side sanity checks.
- Morpho Blue: oracle-agnostic isolated markets where the oracle is part of the immutable market definition.

These examples illustrate architectural patterns; they should not be copied without reviewing the exact current deployment, asset, network, governance, and protocol risk model.
