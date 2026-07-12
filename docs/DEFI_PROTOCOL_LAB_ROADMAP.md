# DeFi Protocol Lab Roadmap

## Goal

Build one progressive `defi-protocol-lab` that develops protocol-level skill in accounting, AMMs, lending, signed intents, fees, account abstraction, upgradeability, EVM mechanics, testing, security, and system design.

The objective is not to clone production protocols. Each module should be the smallest implementation that exposes the important invariants, failure modes, and architectural decisions.

## Repository shape

```text
defi-protocol-lab/
├── src/
│   ├── vault/
│   ├── tokens/
│   ├── staking/
│   ├── amm/
│   ├── oracle/
│   ├── lending/
│   ├── stablecoin/
│   ├── rwa/
│   ├── perps/
│   ├── intents/
│   ├── account/
│   ├── governance/
│   ├── adapters/
│   └── common/
├── test/
│   ├── unit/
│   ├── fuzz/
│   ├── invariant/
│   ├── adversarial/
│   └── fork/
├── script/
├── docs/
│   ├── specifications/
│   ├── invariants/
│   ├── threat-models/
│   ├── decisions/
│   └── audit/
└── README.md
```

Each module should contain:

1. Scope and explicit non-goals.
2. Actors, assets, trust boundaries, and authority graph.
3. Accounting equations and rounding rules.
4. Safety and liveness invariants.
5. Threat model and supported-token assumptions.
6. Implementation.
7. Unit, fuzz, invariant, adversarial, and relevant fork tests.
8. Deployment/operations assumptions.
9. Short architecture decision record.
10. Audit-style findings and remediation pass.

## Phase 0 — Protocol engineering foundations

**Timebox:** 1 week

Study and practise:

- EVM call frames: `CALL`, `DELEGATECALL`, `STATICCALL`, revert data, gas forwarding.
- Storage layout, packing, mappings, inheritance, proxy collisions.
- ABI encoding, selectors, custom errors, low-level calls.
- Fixed-point arithmetic, `Math.mulDiv`, conservative rounding, decimal normalization.
- Checks-effects-interactions and cross-function reentrancy.
- Standard/non-standard ERC-20 behaviour.
- Turning requirements into local postconditions and global invariants.

Deliverables:

- Execution-tracing exercises.
- Decimal/rounding worksheet.
- Shared `TokenBehavior.md` support policy.
- Shared adversarial token mocks.

Exit criteria:

- Predict nested call/storage behaviour without running code.
- Normalize arbitrary token/oracle decimals to a common unit.
- State exact rounding direction for deposit, mint, withdraw, redeem, borrow, and liquidation calculations.

## Phase 1 — Hardened asset/share vault

**Timebox:** 2 weeks

Implement:

- Assets/shares conversions with virtual liquidity.
- `deposit`, `mint`, `withdraw`, and `redeem`.
- Operation-specific slippage limits.
- Exact received-asset validation or explicit unsupported-token policy.
- Internal `_mintShares` and `_burnShares` accounting.
- Management fee based on time and assets.
- Performance fee based on gains, with a documented high-water-mark model.
- Pause matrix and emergency exit assumptions.

Attack classes:

- First-depositor/donation inflation.
- Zero-share deposit and zero-burn withdrawal.
- Fee-on-transfer dilution.
- Reentrant token callbacks.
- Direct donations, rounding extraction, precision loss.
- Incorrect fee accrual and fee-share dilution.

Core invariants:

- Share conservation.
- Asset-flow conservation.
- No free withdrawal.
- No profitable deposit/redeem round trip without external yield.
- Fee minting cannot reduce assets or create unaccounted liabilities.
- Adjusted price per share does not decrease in a no-loss model.

Optional integration:

- Allocate assets through a minimal strategy adapter.
- Fork-test an adapter against an established lending/vault protocol.

### 1B. UUPS vault upgrade laboratory

Use the vault as the primary deep UUPS exercise because its asset/share accounting makes storage corruption and migration errors economically visible.

Implement three deliberately controlled versions:

- `VaultV1`: conversions, deposits, withdrawals, roles, and pause state;
- `VaultV2`: management/performance fee state appended safely;
- `VaultV2Broken`: intentionally incompatible layout used only to prove that tests and storage-layout validation detect corruption.

Required UUPS topics:

- `ERC1967Proxy` deployment with atomic initializer calldata;
- constructors versus initializers and parent initializer ordering;
- disabling initializers on the implementation contract;
- one-time initialization and reinitializers for new modules;
- `_authorizeUpgrade` and least-privilege upgrade authority;
- `onlyProxy`, `notDelegated`, and `proxiableUUID` semantics;
- append-only storage compatibility;
- unsafe variable insertion, deletion, type changes, inheritance reordering, and struct mutation;
- storage gaps versus ERC-7201 namespaced storage;
- `upgradeToAndCall` migrations and migration idempotency;
- malicious/wrong implementation, wrong UUID, zero/no-code target, and implementation initialization;
- upgrade timelock, multisig authority, emergency response, and upgrade-event monitoring;
- intentionally removing or breaking upgrade functionality and proxy-bricking scenarios;
- storage-layout validation in the deployment/CI workflow.

Required tests:

- initializer cannot run twice;
- implementation cannot be initialized directly;
- unauthorized caller cannot upgrade;
- state and balances survive V1 to V2;
- V2 fee fields initialize exactly once;
- incompatible layout is rejected by validation or demonstrated as corrupt in an isolated negative test;
- upgrade to non-UUPS/wrong-UUID implementation reverts;
- upgrade plus migration is atomic;
- failed migration leaves implementation and state unchanged;
- governance delay and role-transfer assumptions are tested.

Do not make every lab contract upgradeable. Compare the UUPS vault with immutable AMM/lending components and document when upgrade risk is less acceptable than redeployment/migration.

### 1C. Token accounting and staking primitives

Build these before relying on them as collateral or protocol receipts:

#### Share-based and rebasing token

- internal shares versus externally visible balances;
- positive and negative rebases;
- total pooled assets/share-rate updates;
- transfer and allowance rounding;
- dust and full-balance transfer corner cases;
- wrapper token with non-rebasing balances;
- integrations that cache balances or assume transfer amounts remain stable;
- rebase during vault, AMM, lending, and governance operations.

#### Staking and rewards

- stake/withdraw/claim;
- `rewardPerToken` accumulator and user reward debt;
- multiple reward epochs and leftover rewards;
- changing stake balances during an epoch;
- fee and treasury share;
- lock/cooldown and emergency withdrawal policy;
- reward funding, undistributed dust, and insolvency;
- optional vote-power relationship without double counting liquid and staked tokens.

#### Minimal LST model

- pooled staking shares;
- validator/delegation accounting represented by a mock staking backend;
- oracle/accounting report that changes pooled assets;
- positive rewards and negative slashing/penalty report;
- withdrawal queue and delayed redemption;
- liquidity mismatch between token supply and immediately withdrawable native assets;
- rebasing LST and wrapped non-rebasing LST;
- use as lending collateral with an LST/native exchange-rate oracle and depeg limits.

Core invariants:

- internal shares sum to total shares;
- visible balances are derived consistently from shares and pooled assets;
- a rebase changes claim value without inventing or deleting internal shares;
- distributed plus remaining staking rewards never exceed funded rewards;
- withdrawal claims cannot exceed available/queued staking assets;
- governance voting power cannot be duplicated through wrapping or staking.

## Phase 2 — AMM, swaps, and oracle mechanics

**Timebox:** 3 weeks

### 2A. Constant-product AMM

Implement a two-token pool with:

- liquidity mint/burn;
- `x * y = k` swaps;
- LP shares;
- swap fee;
- optional protocol-fee share;
- minimum output and deadline;
- reserve synchronization policy.

Study:

- spot price versus execution price;
- price impact versus slippage;
- fee growth and LP economics;
- reserve/balance mismatch;
- minimum-liquidity locking;
- sandwich attacks and MEV;
- fee-on-transfer incompatibilities.

Core invariants:

- Adjusted constant product does not decrease after a fee-paying swap.
- Reserves match the defined accounting source.
- LP supply equals aggregate LP balances.
- A swap cannot output more than available reserves.
- Fees are conserved between LPs and protocol recipients.

### 2B. Oracle engineering module

Treat the oracle as a shared protocol subsystem used by AMM, lending, stablecoin, LST, RWA, paymaster, and perpetual modules.

Implement four educational sources/adapters:

1. Governed/mock push oracle for deterministic unit and failure testing.
2. On-chain AMM spot/TWAP adapter with observation history.
3. Chainlink-style aggregator consumer and local mock aggregator.
4. Optional EIP-712 signed pull report verified on-chain with signer quorum/authorization.

The lab does not attempt to recreate Chainlink's complete off-chain node network. It focuses on producer/consumer trust boundaries, on-chain verification, and safe protocol integration.

Required mechanics:

- decimal normalization;
- positive-price validation;
- staleness checks;
- round/report completeness and monotonic timestamp checks;
- deviation bounds;
- heartbeat versus deviation-trigger semantics;
- L2 sequencer uptime and grace period;
- source-specific confidence/spread where available;
- circuit breakers and last-good-price policy;
- primary/fallback source design without silently accepting inconsistent prices;
- update authorization, signer rotation, and replay protection;
- manipulation-window and liquidity assumptions for TWAP;
- price, rate, NAV, proof-of-reserve, and LST share-rate data types;
- push versus pull delivery and who pays for updates;
- stale/unavailable oracle behavior for deposits, borrowing, liquidation, redemption, and emergency settlement.

Do not assume TWAP is automatically safe. Document manipulation cost, observation window, lag, liquidity, and fallback behaviour.

Oracle invariants and tests:

- normalized values have one documented unit and scale;
- future, stale, zero, negative, replayed, or unauthorized reports are rejected;
- a source switch cannot bypass deviation/circuit-breaker policy;
- a failed oracle cannot silently become a valid zero price;
- protocols fail closed for value-creating actions while preserving intentionally designed unwind paths;
- liquidation behavior during oracle outage is explicit rather than accidental.

### 2C. Concentrated-liquidity study

Do not initially reimplement a full concentrated-liquidity AMM. Instead:

- learn ticks, ranges, liquidity, and square-root price math;
- trace one swap across ticks;
- write small math exercises and fork-based integration tests;
- study singleton/pool-manager and hook architecture after the v2-style invariant is understood.

### 2D. StableSwap/Curve mathematics

After the constant-product pool, implement or derive a minimal two-asset StableSwap model:

- constant-sum behavior near the peg and constant-product protection away from it;
- amplification coefficient `A`;
- invariant `D` and iterative/Newton solving;
- solving output balance `y` and conservative rounding;
- LP mint/burn and virtual price;
- swap fee, admin/protocol fee, and optional dynamic fee;
- unequal decimals and rate providers for yield-bearing/LST assets;
- depeg behavior and liquidity concentration risk;
- imbalanced deposits/withdrawals;
- donation, rounding, convergence, and overflow boundaries;
- study metapools after the plain-pool implementation is understood.

Core tests compare StableSwap and constant-product execution across balanced, mildly imbalanced, and depegged states.

## Phase 3 — Minimal lending protocol

**Timebox:** 4 weeks

Start with one collateral asset and one debt asset.

Implement:

- collateral deposits/withdrawals;
- borrow/repay;
- normalized oracle valuation;
- loan-to-value and liquidation threshold;
- health factor;
- utilization-based interest-rate curve;
- borrow and liquidity indices;
- scaled balances;
- reserve factor/protocol fee;
- partial liquidation, close factor, liquidation bonus;
- bad-debt state and reserve/insurance handling.

Then optionally evolve toward isolated markets rather than immediately building a fully shared multi-asset pool.

Attack/failure classes:

- wrong decimals or stale price;
- oracle manipulation;
- conservative-rounding failure;
- interest-index desynchronization;
- liquidation that worsens a position;
- insufficient collateral for bonus;
- bad-debt socialization;
- borrow/withdraw reentrancy;
- fee-on-transfer or rebasing collateral;
- liquidity exhaustion and withdrawal liveness.

Core invariants:

- Total debt equals aggregate scaled debt multiplied by the current index, within documented rounding.
- Successful borrow/withdraw cannot immediately violate the required HF.
- Repayment cannot increase debt.
- Healthy positions cannot be liquidated.
- Debt decrease equals actual liquidation repayment.
- Seized collateral is bounded by repayment value, bonus, fees, and rounding.
- Cash plus outstanding receivables covers lender claims unless explicit bad debt exists.
- Interest and reserve-fee accrual conserve value.

Advanced exercise:

- Compare share-based lending pools with normalized income/index-based accounting.
- Fork-test a deposit/borrow/repay/liquidation integration against a production lending protocol without copying its implementation.

### 3B. Compound-style cToken/receipt-token accounting

Implement a minimal market receipt token to understand:

- cToken balance versus underlying claim;
- exchange-rate growth;
- `exchangeRateStored` versus state-accruing/current calculations;
- cash, borrows, reserves, and total supply relationship;
- borrow index and per-account borrow snapshots;
- mint/redeem/borrow/repay/liquidate flow;
- reserve factor and protocol reserves;
- underlying/cToken decimal scaling;
- accrual-on-interaction and stale stored values;
- return-code versus revert-based error handling as a historical integration concern.

Compare this with ERC-4626 shares and modern scaled-balance lending accounting rather than copying Compound V2 wholesale.

### 3C. RWA token and lending collateral

Use a mock tokenized RWA to study smart-contract architecture, not jurisdiction-specific legal advice:

- issuer/custodian/transfer-agent roles;
- allowlist/identity and transfer restrictions;
- pause, freeze, forced transfer, redemption, and administrative risk;
- NAV, proof-of-reserve, reserve timestamp, and market-hours semantics;
- off-chain default/custody risk that on-chain code cannot eliminate;
- corporate-action or income-distribution hooks;
- token decimals and settlement delay;
- lending isolation mode, collateral cap, conservative haircut, and debt ceiling;
- stale NAV and unavailable secondary-market liquidity;
- liquidation design when the collateral cannot be transferred permissionlessly or sold continuously.

The oracle layer supplies normalized NAV/price and reserve-status data. Lending must reject or isolate RWA collateral when freshness, reserve, transferability, or market-liquidity assumptions fail.

### 3D. Crypto-backed stablecoin system

Build a minimal overcollateralized stablecoin system reusing the lending and oracle primitives:

- collateral vault/CDP;
- mint/burn stablecoin debt;
- collateral ratio and liquidation ratio;
- stability fee through a debt/rate index;
- per-collateral debt ceiling and global debt ceiling;
- collateral-specific risk parameters;
- liquidation penalty and partial/full liquidation;
- bad-debt and surplus accounting;
- reserve/insurance module;
- peg monitoring and optional bounded peg-stability swap module;
- savings/rate module as an advanced extension;
- emergency shutdown and fair settlement model;
- governance separation between risk, oracle, upgrade, and emergency powers.

Core invariants:

- total stablecoin liabilities reconcile with normalized system debt and explicitly accounted surplus/bad debt;
- minting cannot leave a position below the required collateral ratio;
- debt ceilings cannot be exceeded through rounding or multi-collateral composition;
- repayment/burn cannot increase debt;
- liquidations conserve debt and collateral value under the defined penalty;
- oracle failure cannot mint unbacked stablecoins;
- shutdown fixes a coherent settlement state and prevents new risk creation.

### 3E. Minimal perpetual DEX

Build a local/test-only oracle-priced perpetual engine after AMM, oracle, lending, and stablecoin accounting are understood:

- isolated positions and collateral;
- long/short position size and entry price;
- realized and unrealized PnL;
- initial and maintenance margin;
- funding-rate transfer between long and short sides;
- borrowing/utilization fee paid to liquidity providers;
- open-interest caps and skew;
- price impact based on imbalance;
- increase, decrease, close, and liquidation;
- keeper/order execution with acceptable-price and deadline bounds;
- LP pool solvency and trader-profit liability;
- bad debt, insurance fund, and ADL/socialized-loss concepts;
- oracle delay, stale report, confidence, front-running, and two-phase execution;
- GMX-style pool-backed versus order-book/perp-clearinghouse architecture comparison;
- Hyperliquid-style architecture studied conceptually, with the Solidity implementation limited to EVM-relevant clearing and risk mechanics.

Core invariants:

- position and market open interest reconcile;
- funding is value transfer, not value creation;
- realized PnL plus fees exactly explains collateral changes;
- withdrawals cannot make an open position violate maintenance requirements;
- liquidation cannot pay out more collateral than the position/system owns;
- trader claims plus LP liabilities remain bounded by pool assets or explicit bad debt;
- stale or invalid oracle reports cannot execute value-sensitive orders.

## Phase 4 — EIP-712 intents and keeper execution

**Timebox:** 2 weeks

Implement a signed swap/order executor with:

- EIP-712 domain separation;
- maker-scoped nonce and cancellation;
- signed receiver;
- deadlines;
- partial fills;
- cumulative fill accounting;
- proportional minimum output;
- signed keeper fee and maximum fee;
- optional authorized executor;
- router/route binding policy;
- ERC-1271 contract signatures;
- optional permit flow.

Security focus:

- replay across orders, contracts, chains, and upgrades;
- omitted signed fields;
- nonce griefing;
- signature malleability and incorrect encoding;
- output balance sweeping;
- zero-fill execution;
- router allowance/callback risk;
- MEV and stale execution;
- keeper liveness and gas griefing.

Core invariants:

- Filled input never exceeds signed input.
- Cancelled orders cannot execute.
- Only the signed receiver and fee recipient receive output.
- Keeper compensation never exceeds the signed maximum.
- Execution never sweeps pre-existing executor balances.
- Successful output satisfies the signed proportional price constraint.

## Phase 5 — Smart accounts: ERC-4337 and EIP-7702

**Timebox:** 2–3 weeks

Build a minimal account/execution layer only after EIP-712 and nonce design are solid.

Implement or study:

- batched execution;
- signature validation and ERC-1271;
- replay-safe nonces;
- session keys with scoped permissions;
- spending limits and expiry;
- recovery/guardian design at architecture level;
- ERC-4337 `validateUserOp` versus execution separation;
- EIP-7702 delegation lifecycle and authorization tuple;
- delegated-account storage and initialization hazards;
- interaction between EIP-7702 and ERC-4337.

Capstone flow:

```text
Signed user intent
→ delegated/smart account validation
→ keeper or bundler execution
→ swap
→ vault deposit or lending repayment
→ signed fee settlement
```

Security focus:

- validation/execution mismatch;
- delegate target trust and upgrades;
- storage collisions at the EOA address;
- initialization front-running;
- signature-domain confusion;
- unrestricted batch calls;
- session-key privilege escalation;
- nonce-space conflicts;
- revocation and recovery liveness.

### 5B. Paymasters

All ERC-4337 paymasters ultimately fund gas from native-token deposits held by the EntryPoint. “ERC-20 gas payment” means that the paymaster pays native gas and separately charges/settles ERC-20 value with the user.

Implement two levels:

#### Core: sponsored/verifying paymaster

- EntryPoint deposit and stake lifecycle;
- off-chain EIP-712 sponsorship authorization;
- sender, account nonce, chain, paymaster, validity window, call target/selector, and maximum gas-cost binding;
- replay protection and sponsorship nonce;
- allowlist/quota and per-user budget;
- deterministic, bounded validation;
- failure and gas-griefing tests;
- `postOp` accounting and monitoring.

#### Advanced: ERC-20 paymaster

- supported-token allowlist;
- token/native exchange-rate source and decimal normalization;
- markup/service fee;
- maximum token charge signed or supplied by the user;
- precharge/reservation and `postOp` actual-cost settlement/refund;
- price staleness and slippage bounds;
- fee-on-transfer/rebasing-token policy;
- insufficient token balance/allowance handling;
- EntryPoint deposit solvency;
- failed-operation, reverted-`postOp`, bundler simulation, and griefing cases;
- optional controlled token-to-native replenishment strategy kept separate from validation.

The sponsored paymaster is part of the core curriculum. The ERC-20 paymaster is an advanced extension after oracle, swap, EIP-712, and basic AA modules are complete; it reuses all four areas and should not be attempted earlier.

## Phase 6 — Protocol governance and DAO management

**Timebox:** 2 weeks, with operational governance applied throughout earlier modules

Governance is not only token voting. Separate four authority domains:

- protocol configuration: fees, risk limits, supported assets, oracle and router configuration;
- upgrade governance: UUPS authorization and migrations;
- treasury governance: protocol fees, reserves, paymaster deposits, and grants;
- emergency operations: pause, unpause, guardian cancellation, and incident response.

### 6A. Operational governance

Start with a documented authority matrix for every privileged function:

| Authority | Typical permissions | Expected control |
| --- | --- | --- |
| DAO/Timelock | upgrades and major parameter changes | slow |
| Risk council/multisig | bounded risk parameters | medium |
| Guardian | pause/cancel only | fast |
| Keeper | permissionless or narrowly scoped execution | continuous |
| Treasury | transfers within approved policy | delayed/bounded |

Implement or study:

- `Ownable2Step`, `AccessControl`, and `AccessManager` trade-offs;
- selector-level permissions and execution delays;
- least privilege and separation of duties;
- role grant, revoke, transfer, and renouncement;
- multisig and timelock ownership;
- pause matrix rather than one indiscriminate global pause;
- bounded parameter updates and rate-of-change limits;
- emergency guardian with no upgrade or treasury-withdraw authority;
- deployment bootstrap followed by admin handover/renouncement;
- recovery from unavailable proposers, executors, signers, or guardians;
- on-chain events and off-chain monitoring for every privileged operation.

### 6B. DAO Governor laboratory

Build a minimal DAO around selected `defi-protocol-lab` components:

- `ERC20Votes` governance token or a clearly documented mock voting asset;
- delegation and historical voting checkpoints;
- `Governor` proposal lifecycle;
- proposal threshold;
- voting delay and voting period;
- quorum and vote-counting rules;
- `GovernorTimelockControl` with `TimelockController`;
- proposal queue, execute, cancel, and expiry behaviour;
- governance-controlled UUPS upgrade from `VaultV1` to `VaultV2`;
- governance-controlled fee/risk parameter update;
- governance-controlled treasury transfer;
- optional `GovernorPreventLateQuorum` exercise;
- ERC-6372 clock mode and timestamp-versus-block-number reasoning.

The timelock, not the Governor contract, should ultimately hold governed assets and permissions when using `GovernorTimelockControl`.

### 6C. Governance security and corner cases

Threat-model and test:

- flash-loan/current-balance voting versus historical checkpoints;
- proposal spam and insufficient proposal threshold;
- quorum manipulation and abstain semantics;
- late-quorum attacks;
- vote delegation and redelegation timing;
- signature replay for vote-by-signature;
- malicious multi-call proposal payloads;
- duplicate operation/proposal hashing and salts;
- timelock predecessor dependencies;
- open executor role versus restricted execution;
- proposer/executor/canceller/admin role misconfiguration;
- premature deployer-admin renouncement and permanent governance lockout;
- compromised guardian or council;
- governance capture and malicious upgrades;
- parameter changes that individually pass validation but jointly make the protocol unsafe;
- treasury allowance and arbitrary-call risks;
- emergency pause without an achievable recovery path.

Required tests:

- full propose → vote → queue → delay → execute lifecycle;
- execution before timelock expiry reverts;
- defeated, cancelled, expired, and duplicate proposals cannot execute;
- voting uses historical power at the correct snapshot;
- governance cannot bypass the timelock for protected actions;
- unauthorized actors cannot upgrade or change parameters;
- DAO upgrade preserves vault storage and accounting;
- guardian can pause but cannot upgrade, drain treasury, or silently change risk;
- DAO can recover/rotate operational roles through the timelock;
- no role configuration leaves the protocol unintentionally ownerless or permanently frozen.

### 6D. Governance design deliverable

Produce:

- authority graph;
- privileged-function matrix;
- normal proposal lifecycle;
- emergency lifecycle;
- bootstrap-to-DAO handover plan;
- governance parameter rationale;
- governance attack register;
- incident and signer-loss recovery runbook.

### 6E. Optional TGE and vesting module

Keep this as an optional token-lifecycle and treasury exercise rather than a market-launch project:

- fixed allocation and mint-cap invariants;
- team, treasury, ecosystem, and community allocation accounting;
- cliff plus linear vesting;
- revocable versus irrevocable grants;
- beneficiary transfer policy;
- claim-based vesting rather than automatic iteration;
- Merkle allocation claims and duplicate-claim prevention;
- EIP-712 delegated claims as an optional extension;
- cancellation, clawback, and unallocated-token recovery;
- timestamp boundaries and rounding dust;
- governance-token delegation before/after claim and prevention of duplicated voting power;
- treasury/timelock control and immutable allocation records;
- upgradeability decision and protection against retroactive vesting changes.

Core invariants:

- minted plus mintable supply never exceeds the cap;
- claimed plus still-vested allocation never exceeds the grant;
- vested amount is monotonic and bounded by total allocation;
- cancellation cannot confiscate already vested value;
- one allocation cannot create voting power in both escrow and liquid token form unless explicitly designed.

## Phase 7 — Modern EVM storage and modular architecture

**Timebox:** 1–2 weeks, integrated into earlier modules

### Transient storage (`TSTORE`/`TLOAD`)

Use it for transaction-scoped state such as:

- reentrancy locks;
- callback context;
- flash-accounting deltas;
- temporary authorization flags.

Do not use it for state that must survive the transaction. Confirm target-chain support and understand `CALL`/`DELEGATECALL` ownership semantics before adopting it.

Exercise:

- implement persistent-storage and transient-storage reentrancy guards;
- compare behaviour, gas, composability, and chain compatibility;
- write nested call and delegatecall tests.

### Namespaced storage

Study ERC-7201-style namespaced storage for upgradeable or modular systems:

- deterministic storage namespace;
- storage struct returned through an internal library;
- upgrade append-only rules;
- module namespace collision analysis.

Use namespaced storage when upgradeability/modularity justifies it. Do not add it to every simple immutable contract merely because it is modern.

Compare:

- ordinary inheritance layout;
- storage gaps;
- namespaced storage;
- diamond-style storage;
- immutable, non-upgradeable deployment.

### UUPS versus other deployment models

After completing the vault upgrade laboratory, compare:

- UUPS proxy;
- transparent proxy;
- beacon proxy for fleets;
- clones with immutable/shared implementation;
- immutable redeploy-and-migrate architecture.

The comparison must cover deployment/runtime gas, authority location, selector surface, storage risk, fleet upgrades, migration complexity, and blast radius.

## Phase 8 — Cryptography for protocol engineers

**Timebox:** 2 weeks, partly parallel

Required depth:

- `keccak256`, ABI encoding, packed-encoding collisions;
- ECDSA recovery, low-`s`, `v`, malleability, ERC-2098 compact signatures;
- EIP-191 versus EIP-712;
- ERC-1271 contract signatures;
- nonce models and replay domains;
- Merkle proofs and multiproofs;
- commit-reveal and its limitations;
- CREATE2 commitments;
- signature aggregation concepts;
- BLS, KZG, SNARK/STARK high-level trust and verification models.

Implement:

- EIP-712 signed order;
- ERC-1271 validation path;
- Merkle allowlist/claim;
- commit-reveal exercise;
- negative tests for omitted fields, wrong chain/domain, nonce reuse, and malformed proofs.

Do not implement custom cryptographic primitives for production use.

## Phase 9 — Smart-contract system design patterns

Apply and compare these patterns across the lab:

- core/periphery separation;
- adapter/connector boundary;
- registry and factory;
- minimal proxies/clones;
- command/executor;
- state machine;
- pull-based claims;
- checks-effects-interactions;
- oracle abstraction;
- circuit breaker/pause matrix;
- role-based access versus capability-based modules;
- immutable versus upgradeable core;
- singleton/pool manager;
- modular account/plugins;
- namespaced storage libraries.
- Governor/timelock and operational-authority separation.

For every pattern, document:

1. Problem solved.
2. New trust boundary.
3. New failure mode.
4. Upgrade and storage consequences.
5. Testing implications.

## Phase 10 — Integrated capstone

**Timebox:** 3 weeks

Build a small system rather than another isolated contract:

```text
Smart/delegated account
→ EIP-712 intent
→ keeper executor
→ AMM swap
→ vault deposit or lending repay
→ fee settlement
→ DAO/timelock-controlled upgrades and parameters
```

Required deliverables:

- architecture diagram;
- specification and non-goals;
- accounting equations;
- threat model and authority graph;
- unit/fuzz/invariant/fork tests;
- malicious-token and malicious-router tests;
- storage-layout report;
- gas snapshot;
- deployment script and configuration validation;
- pause/incident runbook;
- governance authority graph and bootstrap handover plan;
- executed DAO proposal for a parameter update and UUPS upgrade;
- audit-style report with remediation commit.

## Suggested 34-week focused sequence

| Weeks | Work |
| --- | --- |
| 1 | EVM, decimals, rounding, invariant foundations |
| 2–3 | Hardened vault and fees |
| 4 | UUPS vault V1→V2, migration, storage corruption lab |
| 5–6 | Rebase token, staking rewards, LST and wrapped LST |
| 7–9 | Constant-product AMM and dedicated oracle engineering |
| 10–11 | StableSwap math, fees, depeg tests and concentrated-liquidity study |
| 12–15 | Lending, interest indices, liquidation, bad debt and cToken comparison |
| 16 | RWA token model and isolated lending collateral |
| 17–19 | Crypto-backed stablecoin, stability fees and shutdown |
| 20–22 | Minimal perpetual engine, funding, PnL, liquidation and LP solvency |
| 23–24 | EIP-712 orders, keepers, partial fills, fees |
| 25–26 | ERC-4337/EIP-7702 account execution |
| 27 | Sponsored/verifying paymaster |
| 28 | ERC-20 paymaster extension |
| 29–30 | Operational governance, DAO Governor, timelock, treasury and UUPS proposal |
| 31 | Transient/namespaced storage and applied cryptography exercises |
| 32 | Optional TGE/vesting or additional adversarial testing |
| 33 | Integrated capstone |
| 34 | Audit, remediation, documentation and design defence |

This is the compressed focused sequence, not a delivery promise. At 6–8 hours per week, expect roughly 42–50 weeks. The ERC-20 paymaster, TGE/vesting, full StableSwap implementation, or perpetual extension may move after the first capstone if schedule pressure appears. Do not sacrifice invariant, economic, oracle-failure, or governance-lifecycle testing to meet the calendar.

## Priority order

### Must master

1. Accounting, decimals, rounding, and conservation.
2. Threat modelling and exact invariants.
3. Vault, AMM, oracle, lending, and liquidation mechanics.
4. Share/rebase/LST, stablecoin, RWA, and perpetual accounting.
5. EIP-712, nonce/replay design, external-call safety.
6. Unit, fuzz, stateful invariant, adversarial, and fork tests.
7. Governance, treasury, upgrades, deployment, and operational risk.

### Strong differentiators

1. Interest/scaled-balance accounting.
2. Concentrated-liquidity integration and math.
3. ERC-4337 and EIP-7702 security.
4. Transient and namespaced storage.
5. Keeper/intent architecture and MEV-aware execution.
6. Audit-quality severity calibration and remediation.
7. DAO/timelock lifecycle, role safety, and governance attack analysis.
8. Oracle architecture across on-chain, push-feed, signed-report, NAV, and reserve data.

### Learn conceptually before implementing deeply

1. Custom cryptographic primitives.
2. Full concentrated-liquidity AMM implementation.
3. Full multi-market lending governance.
4. Cross-chain messaging protocol internals.
5. ZK prover/circuit implementation unless the target role requires it.

## Completion standard

A module is complete only when you can:

- derive its equations and rounding rules;
- state its safety and liveness invariants;
- trace normal and adversarial execution;
- explain every trust assumption;
- demonstrate unit, fuzz, and stateful tests;
- identify production operational risks;
- defend architecture trade-offs without relying on “best practice” as the explanation.
