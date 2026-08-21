# Uniswap V3 Swap Adapter — Execution, Routing, and Fork Validation

## Milestone summary

This milestone adds a reusable Uniswap V3 swap execution adapter to the DeFi Protocol Lab.

The adapter exposes a protocol-facing `ISwapAdapter` API while keeping Uniswap-specific routing, fee encoding, router calls, callback settlement, and exact-output path direction inside the integration boundary.

Implemented execution surface:

```text
Exact Input
├── single-hop
└── multihop

Exact Output
├── single-hop
└── multihop
```

The implementation is covered by unit tests with adversarial router behavior and by Ethereum Mainnet fork tests against the real Uniswap V3 `SwapRouter` and real pools.

At milestone completion, `UniswapV3SwapAdapter` reached:

```text
100% lines
100% statements
100% functions
100% branches
```

The fork suite validates the adapter against pinned real chain state rather than mocks only.

---

## Components

Core contracts and interfaces:

```text
src/labs/swaps/
├── interfaces/
│   ├── ISwapAdapter.sol
│   └── IUniswapV3SwapRouter.sol
└── adapters/
    └── UniswapV3SwapAdapter.sol
```

Supporting reusable primitives:

```text
src/common/token/TokenTransfer.sol
```

Tests:

```text
test/unit/swap/UniswapV3SwapAdapter.t.sol
test/mocks/MockUniswapV3SwapRouter.sol

test/fork/swap/UniswapV3SwapAdapterFork.t.sol
```

The module currently remains under `src/labs/`. Promotion to a reusable protocol-level integration layer should happen only after the abstraction is consumed by a real Vault/Lending/Liquidation component and survives that composition without major API redesign.

---

# 1. Architecture

The adapter is a protocol-to-DEX integration boundary.

```text
Vault / Lending / Liquidation / Strategy
                |
                v
          ISwapAdapter
                |
                v
      UniswapV3SwapAdapter
                |
                v
      Uniswap V3 SwapRouter
                |
                v
          Uniswap V3 Pools
```

The protocol-facing layer describes **intent**:

```text
tokenIn
tokenOut
amount constraints
recipient
deadline
route
```

The adapter owns DEX-specific interpretation:

```text
fee encoding
packed V3 path
exactInputSingle()
exactInput()
exactOutputSingle()
exactOutput()
reversed exact-output path
```

This prevents higher-level protocol components from depending directly on Uniswap V3 router structs and path encoding.

---

# 2. Generic swap API

## Exact input

Mental model:

```text
Spend exactly X tokenIn
receive at least Y tokenOut
```

Protocol fields:

```solidity
struct ExactInputParams {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
    address recipient;
    uint256 deadline;
    bytes route;
}
```

Example:

```text
Spend exactly: 1 WETH
Receive at least: 1,850 USDC
```

The returned value is the actual `amountOut`.

---

## Exact output

Mental model:

```text
Receive exactly Y tokenOut
spend no more than X tokenIn
```

Protocol fields:

```solidity
struct ExactOutputParams {
    address tokenIn;
    address tokenOut;
    uint256 amountOut;
    uint256 maxAmountIn;
    address recipient;
    uint256 deadline;
    bytes route;
}
```

Example:

```text
Receive exactly: 10,000 USDC
Spend at most: 5.2 WETH
```

The returned value is the actual `amountIn`.

This semantic difference matters for lending and liquidation flows:

```text
Exact input:
"I have this collateral amount; sell it."

Exact output:
"I must obtain exactly this repayment amount;
sell no more collateral than necessary."
```

---

# 3. Single-hop route encoding

For the lab adapter, single-hop route data is deliberately minimal:

```solidity
route = abi.encode(uint24(fee));
```

This occupies 32 ABI bytes.

Example:

```solidity
abi.encode(uint24(500))
```

means:

```text
single-hop
fee tier = 500 = 0.05%
```

The adapter then constructs the full router struct from protocol-level `tokenIn`, `tokenOut`, recipient, deadline, and amount constraints.

This design avoids arbitrary router calldata and keeps control over the external call inside the adapter.

---

# 4. Uniswap V3 packed multihop path

A V3 path is tightly packed:

```text
token | fee | token | fee | token ...
```

Sizes:

```text
address = 20 bytes
uint24  =  3 bytes
```

For:

```text
WETH -> USDC -> WBTC
```

an exact-input path can be:

```text
WETH | 500 | USDC | 3000 | WBTC
```

encoded as:

```solidity
abi.encodePacked(
    WETH,
    uint24(500),
    USDC,
    uint24(3000),
    WBTC
);
```

Size:

```text
20 + 3 + 20 + 3 + 20 = 66 bytes
```

General formula:

```text
path length = 20 + N * 23
```

where `N` is the number of hops/pools.

Examples:

```text
1 hop  = 43 bytes
2 hops = 66 bytes
3 hops = 89 bytes
```

The adapter deliberately uses a separate 32-byte representation for its single-hop branch, so packed paths accepted by the multihop branch must contain at least two hops:

```text
path.length >= 66
(path.length - 20) % 23 == 0
```

This gives an unambiguous API:

```text
32 bytes          -> single-hop adapter route
66, 89, 112, ... -> multihop V3 packed path
anything else     -> InvalidRoute
```

---

# 5. Exact-input path direction

For exact input, route direction follows actual token flow:

```text
tokenIn -> ... -> tokenOut
```

Example:

```text
economic flow:
WETH -> USDC -> WBTC

packed exact-input path:
WETH | 500 | USDC | 3000 | WBTC
```

Endpoint invariant:

```text
first path token == params.tokenIn
last path token  == params.tokenOut
```

The adapter validates both endpoints before moving user funds.

---

# 6. Exact-output path direction — important V3 trap

Exact-output paths are encoded **backwards**.

For the same economic route:

```text
WETH -> USDC -> WBTC
```

the router path is:

```text
WBTC | 3000 | USDC | 500 | WETH
```

Why?

Exact output is solved backwards:

```text
How much USDC is required for exactly X WBTC?
                    ^
                    |
How much WETH is required for that USDC amount?
```

Therefore the router walks:

```text
desired output -> previous token -> original input
```

Endpoint invariant becomes:

```text
first path token == params.tokenOut
last path token  == params.tokenIn
```

### Important: reverse the hop sequence, not just token names

If the exact-input route is:

```text
WETH --500--> USDC --3000--> WBTC
```

the corresponding exact-output route through the **same pools** is:

```text
WBTC --3000--> USDC --500--> WETH
```

The fees move with their pool/hop.

A route such as:

```text
WBTC --500--> USDC --3000--> WETH
```

may still be valid if those fee-tier pools exist, but it is a different route through different pools.

This is an easy implementation and interview mistake.

---

# 7. Path endpoint decoding

The adapter only needs to decode the first and last token for validation.

It does not need to decode every intermediate token or fee.

First token:

```solidity
assembly {
    token := shr(96, calldataload(path.offset))
}
```

`calldataload` reads 32 bytes:

```text
[20-byte address][12 bytes of following path data]
```

Shifting right by 96 bits removes the trailing 12 bytes.

Last token begins at:

```text
path.offset + path.length - 20
```

and is decoded the same way.

The helper return name should stay direction-neutral (`token` rather than `tokenIn`/`tokenOut`) because the meaning changes between exact input and exact output.

---

# 8. Custody and allowance model

The adapter deliberately acts as a temporary custody boundary.

For exact input:

```text
caller
  |
  | amountIn
  v
adapter
  |
  | temporary approval = amountIn
  v
router
  |
  v
pool(s)

tokenOut -> recipient
```

For exact output:

```text
caller
  |
  | maxAmountIn
  v
adapter
  |
  | temporary approval = maxAmountIn
  v
router
  |
  | actual amountIn
  v
pool(s)

exact amountOut -> recipient

unused tokenIn -> caller refund
```

Important invariant:

```text
Router never receives a direct allowance from the higher-level protocol/caller.
```

The caller approves the adapter; the adapter grants a narrow temporary allowance to its immutable trusted router.

---

# 9. Why `pullExact` is used

The adapter uses:

```solidity
TokenTransfer.pullExact(...)
```

This means the adapter requires the exact requested input amount to arrive.

This is not just because the function is named "exact input".

It is an explicit token-behavior assumption:

```text
requested transfer amount == actual received amount
```

Fee-on-transfer / transfer-tax inputs violate this invariant and are therefore unsupported by this V1 adapter.

For exact output, the adapter pulls exactly `maxAmountIn`, lets the router consume only the required portion, then refunds the remainder.

---

# 10. Allowance lifecycle

The router approval is temporary:

```text
pull tokenIn
-> approve router
-> external router call
-> approve router = 0
```

Why reset?

It reduces lingering token authority after the swap.

Post-success invariant:

```text
allowance(adapter, router) == 0
```

If the router call reverts, the entire transaction rolls back, including the previous token pull and approval.

---

# 11. Exact-output refund accounting

Example:

```text
caller owns:     10.00 WETH
maxAmountIn:      5.20 WETH
actual amountIn:  4.85 WETH
```

Execution:

```text
adapter pulls        5.20
router consumes      4.85
adapter remainder    0.35
refund to caller     0.35
```

Final caller expenditure:

```text
4.85 WETH
```

Formula:

```solidity
refund = maxAmountIn - actualAmountIn;
```

Never:

```text
amountOut - amountIn
```

because those values represent different assets and usually different decimals.

Refund goes to `msg.sender`, the party that supplied `tokenIn`.

`params.recipient` is the recipient of `tokenOut`; it may be a different address.

---

# 12. Adapter-level defense-in-depth

The real Uniswap router enforces its own swap bounds, but the adapter also checks its abstraction contract.

Exact input:

```solidity
if (receivedAmount < params.minAmountOut) {
    revert InsufficientAmountOut(...);
}
```

Exact output:

```solidity
if (amountIn > params.maxAmountIn) {
    revert ExcessiveAmountIn(...);
}
```

For a canonical router these conditions are largely defensive/redundant.

They remain useful because the adapter should not blindly trust a configured external contract's return value.

Unit tests intentionally use a non-conforming mock router to prove these adapter-level checks.

---

# 13. `sqrtPriceLimitX96`

The adapter intentionally uses:

```solidity
sqrtPriceLimitX96: 0
```

`0` does **not** mean "price must reach zero".

For Uniswap V3 periphery this is a sentinel meaning no caller-specified custom price boundary; the router substitutes the appropriate extreme permitted price limit for the swap direction.

A custom non-zero limit introduces additional semantics, including the possibility that a swap stops before consuming all intended input.

That would require additional residual-input/refund rules for exact input.

For V1, keeping the value at `0` preserves a clean execution contract.

---

# 14. Uniswap V3 callback mental model

One of the most important lessons from the fork tests is how V3 settlement actually works.

A simplified exact-output flow:

```text
EOA
└─ Adapter.swapExactOutput()
   └─ SwapRouter.exactOutputSingle()
      └─ Pool.swap()
         ├─ tokenOut.transfer(recipient)
         └─ SwapRouter.uniswapV3SwapCallback(...)
            └─ tokenIn.transferFrom(adapter, pool)
```

This is all inside **one EVM transaction and one nested call stack**.

There is no asynchronous callback and no second transaction.

---

## Why the callback exists

The pool can calculate the required input while executing the swap.

For exact output:

```text
want exactly 10 USDC
```

the pool determines:

```text
required WETH = X
```

It sends the output according to swap semantics and then calls the router back to settle the positive token delta.

Conceptually:

```text
negative pool delta = pool sent that token
positive pool delta = pool must receive that token
```

Example from the real fork test:

```text
pool USDC delta = -10 USDC
pool WETH delta = +~0.005325 WETH
```

The callback then pays the WETH owed to the pool.

---

## Who pays?

The router executes the callback but does not necessarily pay using its own balance.

Callback data identifies the payer.

In this adapter architecture:

```text
payer = UniswapV3SwapAdapter
```

The router has been temporarily approved by the adapter, so settlement becomes:

```text
WETH.transferFrom(adapter, pool, requiredAmount)
```

The pool itself does not need an allowance from the adapter.

---

# 15. Why callback settlement is powerful

The callback model enables atomic DeFi composition.

The caller can potentially obtain the owed token during the same call stack from:

```text
another pool
another protocol
a flash loan
its own balance
```

as long as the current pool is fully paid before the callback returns.

This "execute, calculate debt, settle before returning" structure is fundamental to understanding Uniswap V3 composability.

---

# 16. Atomic rollback — real fork proof

A negative multihop exact-output fork test used a deliberately too-low `maxAmountIn`.

Conceptually:

```text
desired output:
27,000 WBTC raw units

required WETH:
~0.009+ WETH

allowed maximum:
0.003 WETH
```

Inside the transaction, traces show intermediate/output transfers occurring before the final WETH settlement fails.

However, the final state is:

```text
user WETH unchanged
user WBTC unchanged
adapter WETH = 0
adapter USDC = 0
adapter WBTC = 0
adapter -> router allowance = 0
```

This demonstrates a critical EVM property:

```text
an internal transfer visible in a trace is not necessarily committed state
```

If any nested call reverts and the revert propagates to the top-level transaction, all previous state changes in that transaction are reverted.

---

# 17. Understanding raw `swap()` return data

Uniswap V3 pool `swap()` returns two signed integers:

```solidity
(int256 amount0, int256 amount1)
```

ABI encoding uses one 32-byte word for each value:

```text
32 bytes amount0
32 bytes amount1
```

A negative signed integer is encoded in two's complement, so it appears as:

```text
0xffffffffffff....
```

A trace such as:

```text
0xffff.... | 0x0000....
```

is therefore just the encoded pair of signed token deltas.

Do not interpret the long hex as an opaque protocol-specific hash.

---

# 18. Real USDC proxy behavior observed in fork traces

Fork traces show:

```text
USDC proxy address
0xA0b869...
    |
    | delegatecall
    v
implementation
```

For example, an external:

```text
USDC.transfer(...)
```

appears as a call to the canonical USDC address followed by an implementation `delegatecall`.

This is normal upgradeable-proxy behavior:

```text
code executes from implementation
storage belongs to proxy
msg.sender is preserved
address(this) remains the proxy context
```

Fork tests therefore also demonstrate why integration tests are valuable: real token deployment architecture is often more complex than the ERC20 mocks used in unit tests.

---

# 19. Unit test strategy

The mock router intentionally does **not** implement AMM math.

Its purpose is to exercise the adapter boundary:

```text
capture parameters
pull configured token amounts
send configured output
return configured values
optionally revert
optionally behave inconsistently
```

Important adversarial case:

```text
router physically spends <= maxAmountIn
but reports amountIn > maxAmountIn
```

This reaches the adapter's `ExcessiveAmountIn` defense-in-depth check.

If the mock instead physically tries to spend above the allowance, ERC20 allowance enforcement reverts first and the adapter check is never reached.

---

# 20. Unit coverage

The unit suite covers:

## Deployment

- valid router;
- zero router;
- EOA/no-code router.

## Exact input

- single-hop success;
- multihop success;
- minimum output;
- router revert propagation;
- zero token addresses;
- zero recipient;
- same token;
- zero amount input;
- zero minimum output;
- expired deadline;
- exact deadline boundary;
- malformed route lengths;
- token endpoint mismatch;
- allowance reset;
- zero residual balances;
- transaction rollback.

## Exact output

- single-hop success;
- multihop success;
- refund path;
- no-refund path;
- router revert;
- excessive reported input;
- zero output;
- zero maximum input;
- zero token addresses;
- zero recipient;
- same token;
- expired deadline;
- malformed route;
- reversed multihop endpoint mismatch;
- zero residual balances;
- allowance reset;
- atomic rollback.

Milestone result:

```text
UniswapV3SwapAdapter.sol
100% lines / statements / functions / branches
```

---

# 21. Foundry fork testing strategy

Mental model:

> Unit tests prove our logic. Fork tests prove our assumptions about external protocols.

Fork tests are intentionally small and high-value.

They do not duplicate every unit validation.

---

## Pin the fork block

The suite uses a fixed Ethereum Mainnet block:

```text
FORK_BLOCK = 25,600,000
```

Pinning the block makes the fixture reproducible:

```text
same contracts
same pool state
same liquidity
same ticks
same timestamp
```

Avoid using "latest" for deterministic integration tests.

---

## RPC configuration

`foundry.toml`:

```toml
[rpc_endpoints]
mainnet = "${MAINNET_RPC_URL}"
```

The RPC URL belongs in the environment / local `.env`, never in Git.

---

## Real contracts, local adapter

Fork model:

```text
forked Ethereum state:
- real WETH
- real USDC
- real WBTC
- real Uniswap V3 Factory
- real SwapRouter
- real pools

local deployment:
- UniswapV3SwapAdapter
```

External protocol state is not patched.

---

## User WETH setup

Instead of mutating WETH token storage directly, the test funds the user with ETH and calls real WETH:

```text
vm.deal(user, ...)
WETH.deposit{value: ...}()
```

This is not strictly required for adapter testing, but it is cheap and keeps the fixture close to real token behavior.

---

# 22. Fork fixture sanity checks

The fork setup verifies that:

```text
WETH code exists
USDC code exists
router code exists
factory code exists
expected pool code exists
```

It also asks the real factory:

```solidity
factory.getPool(tokenA, tokenB, fee)
```

and checks the returned pool address.

This catches:

```text
wrong chain
wrong constants
wrong fee tier
wrong RPC/fork state
```

before running swap logic.

---

# 23. Fork scenarios completed

The real-router suite validates:

```text
1. exactInputSingle
   WETH -> USDC

2. exactInput multihop
   WETH -> USDC -> WBTC

3. exactOutputSingle
   WETH -> USDC

4. exactOutput multihop
   WETH -> USDC -> WBTC
   using reversed router path

5. exactOutput multihop failure
   too-low maxAmountIn
   -> real callback settlement failure
   -> full atomic rollback
```

The important assertions are observable effects, not router internals:

```text
input balance delta
output balance delta
returned amount
min/max constraint
zero adapter residual balances
zero router allowance
full rollback on failure
```

---

# 24. What the fork tests proved

The fork suite validates assumptions that mocks cannot fully prove:

```text
our router ABI matches real SwapRouter
single-hop fee encoding is correct
multihop packed paths are correct
exact-output reverse path is correct
callback settlement works with adapter custody
temporary allowance is sufficient
real exact-output consumes less than maxAmountIn
refund accounting works against real execution
intermediate multihop tokens stay out of the adapter
failure deep inside nested callbacks rolls back everything
```

This is the main reason the fork milestone is important despite already having 100% unit coverage.

---

# 25. Fork test best practices to remember

1. **Pin a block** for deterministic protocol state.
2. **Keep RPC secrets outside Git.**
3. **Use real external contracts** and deploy only the component under test locally.
4. **Do not mutate protocol pool state** unless that mutation is itself the test subject.
5. **Seed only the minimum user state necessary.**
6. **Assert observable invariants**, not implementation details of external protocols.
7. **Do not duplicate the full unit suite on a fork.**
8. **Use economically meaningful slippage bounds**, not `minAmountOut = 1`.
9. **Avoid exact quote assertions** unless exact arithmetic at a pinned block is specifically the subject.
10. **Include at least one real failure path** to prove rollback/constraint behavior.
11. **Separate fork tests from unit tests** so CI can run them independently.
12. **Treat fork tests as integration compatibility proofs, not production audits.**

---

# 26. Security and trust assumptions

## Trusted router

The adapter stores an immutable router address and verifies at construction that it is non-zero and has code.

The adapter still assumes that the configured router is trusted/canonical.

A malicious router could exploit its temporary token allowance within the allowed amount.

Deployment configuration therefore remains part of the security boundary.

---

## Fee-on-transfer input tokens

Unsupported.

The adapter requires exact receipt through `TokenTransfer.pullExact`.

---

## Output token behavior

The adapter relies on the trusted router's returned amount and real token transfer semantics.

The V1 design does not independently measure arbitrary recipient balance deltas for every swap.

---

## Price protection

The adapter does not calculate a slippage bound.

The caller/protocol must provide:

```text
minAmountOut
or
maxAmountIn
```

A higher-level protocol may derive these from:

```text
oracle price
TWAP
off-chain routing/quoting
risk parameters
```

Keeping quoting separate from execution avoids mixing price discovery with the token execution boundary.

---

## `sqrtPriceLimitX96`

Not exposed in V1.

The adapter fixes it to zero for single-hop calls.

---

## Route validation is structural, not economic

The adapter validates:

```text
path length
path endpoints
```

It does not prove:

```text
pool existence for every hop
pool liquidity
economic quality of the route
canonical factory provenance for each encoded hop
```

The trusted router/pools and caller-provided constraints handle those aspects.

---

## Reentrancy

The adapter performs external token/router calls.

No `nonReentrant` modifier was added merely by default.

Whether a reentrancy guard is required should follow an explicit threat model and composition analysis, especially when the adapter becomes callable through stateful Vault/Lending components.

Do not add a modifier just to satisfy a pattern checklist.

---

# 27. Why the module still lives under `src/labs`

High coverage plus fork validation makes the adapter significantly more mature, but promotion to a protocol-level primitive should also prove composition.

A useful promotion checklist:

```text
stable interface
real external integration validated
used by at least one real protocol consumer
trust assumptions documented
failure semantics understood
unit + integration tests present
no educational-only shortcuts affecting the consumer
```

Recommended progression:

```text
src/labs/swaps
    |
    | first real Vault/Lending/Liquidation consumer
    v
architecture review
    |
    v
possible promotion:
src/integrations/swaps/
```

The consumer is an important design test: if the interface survives real reuse without being redesigned, it is strong evidence that the abstraction is mature.

---

# 28. What is intentionally out of scope for V1

Do not extend the adapter merely for completeness.

Current deliberate non-goals:

```text
custom sqrtPriceLimitX96
Universal Router
SwapRouter02-specific API
Permit2
native ETH wrapping/unwrapping inside adapter
route discovery
on-chain quoting
Quoter integration
fee-tier discovery
pool liquidity validation
arbitrary router calldata
fee-on-transfer token support
automatic oracle-derived slippage
aggregator routing
```

These can be added later when a real consumer requires them.

---

# 29. Interview refresh — likely questions

## Q1. What is the difference between exact input and exact output?

**Exact input:**

```text
amountIn is fixed
amountOut is variable but bounded below
```

**Exact output:**

```text
amountOut is fixed
amountIn is variable but bounded above
```

Exact output is particularly useful when a protocol must obtain an exact repayment/debt amount while minimizing collateral sold.

---

## Q2. Why is an exact-output multihop path reversed in Uniswap V3?

Because required inputs must be calculated backwards from the desired output.

For:

```text
WETH -> USDC -> WBTC
```

the router first determines the USDC required for the desired WBTC and then determines the WETH required for that USDC.

Therefore the encoded exact-output path is:

```text
WBTC -> USDC -> WETH
```

with each fee remaining attached to its corresponding pool.

---

## Q3. What is the Uniswap V3 packed-path format?

```text
token(20 bytes) | fee(3 bytes) | token(20 bytes) | ...
```

General length:

```text
20 + N * 23
```

where `N` is the number of hops.

---

## Q4. Why not use `abi.encode` for a V3 multihop path?

`abi.encode` pads values into 32-byte ABI slots.

Uniswap V3 expects a tightly packed path:

```text
20 | 3 | 20 | 3 | 20
```

so the path is created with `abi.encodePacked`.

---

## Q5. How does `uniswapV3SwapCallback` work?

The pool executes swap accounting and calls the router back with token deltas.

A positive delta means the pool must be paid that token.

The router settles the debt before the callback returns, often by `transferFrom` from the original payer.

The callback is synchronous and occurs within the same EVM transaction.

---

## Q6. Why use a callback instead of transferring input to the pool before calling `swap()`?

The exact required input may only become known after swap math executes, especially for exact-output swaps.

Callback settlement lets the pool compute the obligation first and require payment atomically before returning.

It also enables advanced atomic composition such as multihop routing and flash-style interactions.

---

## Q7. Who pays the pool in this adapter architecture?

The adapter temporarily holds the input token and approves the trusted router.

The router's callback uses `transferFrom(adapter, pool, requiredAmount)`.

The higher-level caller does not approve the Uniswap pool/router directly.

---

## Q8. Why reset router allowance to zero?

To avoid leaving unnecessary token authority after execution.

The allowance exists only around the external router interaction.

---

## Q9. Why pull `maxAmountIn` for exact output?

The actual required input is not known before execution.

The adapter therefore acquires the maximum allowed amount, grants the router that limit, lets it consume the actual amount, and refunds the remainder.

---

## Q10. Who receives the exact-output refund?

The input provider, `msg.sender`.

The output `recipient` may be a different account.

---

## Q11. Can a router spend more than `maxAmountIn`?

Not through a standard ERC20 `transferFrom` if its allowance is only `maxAmountIn`.

The token allowance is the physical capability boundary.

The adapter additionally validates the router's returned `amountIn` as defense-in-depth.

---

## Q12. Why test `ExcessiveAmountIn` with a deliberately inconsistent mock?

If the mock physically tries to pull more than the allowance, ERC20 allowance enforcement reverts first.

To reach the adapter-level check, the mock must spend no more than allowed but maliciously report a larger return value.

This separates token-capability enforcement from semantic return-value validation.

---

## Q13. What does `sqrtPriceLimitX96 = 0` mean?

It is a periphery sentinel meaning no custom caller-specified price limit.

It does not mean a literal zero price.

---

## Q14. Why are fee-on-transfer tokens problematic?

`amountIn` semantics assume the adapter receives exactly the specified amount.

A transfer-tax token may deliver less than requested, breaking router funding and accounting assumptions.

This V1 rejects such behavior through `pullExact`.

---

## Q15. What do fork tests add beyond 100% unit coverage?

Unit tests prove local logic against controlled dependencies.

Fork tests prove assumptions about:

```text
real router ABI
real pool behavior
callback settlement
real token contracts/proxies
path encoding
nested protocol calls
actual refund mechanics
```

Coverage percentage alone cannot establish external compatibility.

---

## Q16. Why pin the fork block?

To make the integration fixture reproducible.

Without pinning:

```text
liquidity
ticks
prices
pool state
block.timestamp
```

change over time and can make tests flaky.

---

## Q17. Should fork tests reproduce every unit validation?

No.

Fork tests should target high-value external integration assumptions.

Validation branches such as zero addresses or malformed parameters are cheaper and clearer in deterministic unit tests.

---

## Q18. Why can a transfer appear in a trace even though the final balance is unchanged?

Because the transfer occurred inside a transaction that later reverted.

EVM state changes are atomic at transaction level; propagated revert discards all prior state mutations in that call tree.

---

## Q19. What are the two signed values returned by a V3 pool `swap()`?

The pool returns:

```solidity
(int256 amount0, int256 amount1)
```

They represent token balance deltas from the pool's perspective.

Negative values are ABI-encoded using two's complement and therefore appear as long `0xffff...` words.

---

## Q20. Why use an adapter rather than call the router directly from every Vault/Lending contract?

An adapter isolates:

```text
DEX-specific ABI
route encoding
approval lifecycle
token custody
refund accounting
validation
```

Higher-level protocols consume a stable swap intent API and can later swap integration implementations without embedding router-specific logic everywhere.

---

# 30. Short mental checklist

When integrating a router-based DEX:

```text
[ ] What exactly is fixed: input or output?
[ ] What are the caller's min/max economic bounds?
[ ] Who owns tokenIn before execution?
[ ] Who receives tokenOut?
[ ] Who receives unused tokenIn?
[ ] Who gets allowance and for how much?
[ ] Is allowance cleared afterward?
[ ] Are transfer-tax tokens supported or rejected?
[ ] How is route data encoded?
[ ] Are path endpoints validated?
[ ] Does exact-output reverse path direction?
[ ] Are fee tiers attached to the correct hops?
[ ] How does callback settlement obtain payment?
[ ] What happens if a deep nested call reverts?
[ ] What residual balances may remain?
[ ] Which assumptions are verified by unit tests?
[ ] Which assumptions require real fork tests?
[ ] Is the external router trusted configuration?
```

---

# 31. Milestone completion criteria

This V3 execution milestone is considered complete when:

- `ISwapAdapter` supports exact input and exact output intents.
- `UniswapV3SwapAdapter` supports single-hop exact input.
- `UniswapV3SwapAdapter` supports multihop exact input.
- `UniswapV3SwapAdapter` supports single-hop exact output.
- `UniswapV3SwapAdapter` supports multihop exact output.
- Exact-output packed paths use reverse hop order.
- Multihop path structure and endpoints are validated.
- Input tokens are pulled exactly.
- Router allowance is temporary and reset to zero.
- Exact-output unused input is refunded to the caller.
- Adapter-level min-output/max-input checks are present.
- Unit tests cover normal and adversarial router behavior.
- Adapter unit coverage is 100% across lines, statements, functions, and branches.
- Fork fixture uses a pinned Ethereum Mainnet block.
- Real WETH/USDC exact-input execution passes.
- Real WETH/USDC/WBTC multihop exact-input execution passes.
- Real WETH/USDC exact-output execution proves refund behavior.
- Real WETH/USDC/WBTC multihop exact-output execution passes with the reversed path.
- Too-low real `maxAmountIn` produces a router/callback failure and full atomic rollback.
- Adapter retains no swap-token balances after successful execution.
- Adapter retains no router allowance after successful execution.

---

# 32. Next architecture checkpoint

Do not add more V3 functionality merely to make the adapter larger.

The next useful exercise is to test whether the generic abstraction survives a fundamentally different DEX architecture.

Candidate:

```text
ISwapAdapter
├── UniswapV3SwapAdapter
└── UniswapV4SwapAdapter
```

Uniswap V4 introduces substantially different mechanics:

```text
singleton PoolManager
PoolKey
Currency
flash accounting / settlement
hooks
dynamic fees
native ETH support
```

The key architecture question is not "can we implement more swap functions?"

It is:

> Does the current protocol-facing `ISwapAdapter` remain useful when the underlying DEX execution model changes significantly?

That is a stronger test of the abstraction than adding more V3-specific features.
