# Solidity Vault Hardening Checklist

Use this checklist when designing, implementing, reviewing, or testing an asset/share vault. It assumes a standard non-rebasing ERC-20 unless the specification explicitly supports other token behavior.

## 1. Define the accounting model first

* [ ] Clearly distinguish assets from shares.
* [ ] Document what `totalAssets()` includes: idle balance, strategy debt, accrued yield, pending fees, and direct donations.
* [ ] Define whether share price may decrease and which events may cause it.
* [ ] Write conversion equations before implementing entry points.
* [ ] Keep share supply consistent with the sum of all account share balances.
* [ ] Never increase user liabilities without receiving or recognizing corresponding assets.
* [ ] Use full-precision `Math.mulDiv` instead of `x * y / z` where multiplication may overflow or lose unnecessary precision.

## 2. Apply caller-unfavourable rounding

| Operation  | User specifies | Vault calculates | Round          |
| ---------- | -------------- | ---------------- | -------------- |
| `deposit`  | assets         | shares           | down (`Floor`) |
| `mint`     | shares         | assets           | up (`Ceil`)    |
| `withdraw` | assets         | shares           | up (`Ceil`)    |
| `redeem`   | shares         | assets           | down (`Floor`) |

* [ ] Rounding must favour the vault and existing shareholders, never the caller performing the conversion.
* [ ] A positive successful deposit must not mint zero shares.
* [ ] A positive successful withdrawal must not burn zero shares.
* [ ] Reject zero-output conversions where accepting them would transfer value without consideration.
* [ ] Keep conversion helpers and state-changing functions consistent.

## 3. Protect initialization and donation handling

* [ ] Model the empty-vault and first-depositor cases explicitly.
* [ ] Assume anyone can transfer the asset directly to the vault.
* [ ] Protect against donation/inflation attacks using a justified mechanism such as virtual assets/shares, a decimals offset, or locked initial liquidity.
* [ ] Treat `VIRTUAL_ASSETS = 1` and `VIRTUAL_SHARES = 1` as basic mitigation, not complete griefing protection.
* [ ] Test whether an attacker can manipulate the exchange rate so a later depositor receives zero or disproportionately few shares.
* [ ] Require user-supplied slippage bounds even when inflation protection exists.

Example virtual-liquidity conversions:

```solidity
shares = Math.mulDiv(
    assets,
    totalSupply + VIRTUAL_SHARES,
    totalAssets() + VIRTUAL_ASSETS,
    rounding
);

assets = Math.mulDiv(
    shares,
    totalAssets() + VIRTUAL_ASSETS,
    totalSupply + VIRTUAL_SHARES,
    rounding
);
```

## 4. Enforce operation-specific slippage

* [ ] `deposit(assets, minShares)` reverts when `shares < minShares`.
* [ ] `mint(shares, maxAssets)` reverts when `assets > maxAssets`.
* [ ] `withdraw(assets, maxShares)` reverts when `shares > maxShares`.
* [ ] `redeem(shares, minAssets)` reverts when `assets < minAssets`.
* [ ] Do not require a minimum parameter itself to be nonzero; zero means the caller elected to accept no meaningful protection.
* [ ] Add deadlines when quotes may become stale between signing/submission and execution.

Mnemonic: minimum output fails when actual is lower; maximum input fails when actual is higher.

## 5. State token assumptions explicitly

* [ ] Decide whether fee-on-transfer tokens are supported or rejected.
* [ ] If rejected on deposit/mint, verify the exact received balance delta.
* [ ] Do not assume `SafeERC20` verifies the transferred amount; it primarily handles token call/return behavior.
* [ ] Decide whether rebasing tokens are supported; document how positive and negative rebases affect share price.
* [ ] Consider ERC-777-like hooks, malicious callbacks, tokens returning no value, tokens returning false, pausable/blocklisted tokens, and tokens with unusual decimals.
* [ ] Consider tokens whose recipient receives less than the vault sends; an incoming balance check alone does not protect withdrawal recipients.
* [ ] Allowlist supported assets when arbitrary token behavior cannot be safely normalized.

Exact incoming-transfer check:

```solidity
uint256 assetsBefore = totalAssets();
asset.safeTransferFrom(msg.sender, address(this), assets);
uint256 assetsAfter = totalAssets();

if (
    assetsAfter < assetsBefore
        || assetsAfter - assetsBefore != assets
) revert UnsupportedTokenBehavior();
```

## 6. Harden external interactions

* [ ] Use `SafeERC20`; do not treat it as a reentrancy guard.
* [ ] Apply `nonReentrant` where token or strategy calls can re-enter vault entry points.
* [ ] Follow checks-effects-interactions where compatible with the accounting model.
* [ ] Burn shares before transferring assets out.
* [ ] For deposit/mint, calculate using pre-transfer state, validate the actual received amount, then mint shares.
* [ ] Review cross-function reentrancy, not only re-entry into the same function.
* [ ] Avoid arbitrary external hooks; use internal hooks unless an external call is required and threat-modelled.
* [ ] Propagate or deliberately handle external-call failure.

## 7. Keep entry-point semantics distinct

* [ ] `deposit` means exact assets in, minimum shares out.
* [ ] `mint` means maximum assets in, exact shares out.
* [ ] `withdraw` means exact assets out, maximum shares burned.
* [ ] `redeem` means exact shares burned, minimum assets out.
* [ ] Separate user-facing `mint()` from internal `_mintShares()` accounting.
* [ ] Check owner balance/allowance before burning shares on behalf of another account.
* [ ] Emit events containing caller, owner, receiver, assets, and shares as appropriate.

## 8. Prevent accounting and implementation errors

* [ ] Use one authoritative conversion path rather than duplicating formulas across entry points.
* [ ] Take all values used in one conversion from a consistent state snapshot.
* [ ] Avoid division by zero through virtual liquidity or explicit initialization rules.
* [ ] Validate asset and share decimals and any decimals offset.
* [ ] Use custom errors that describe the actual failure: balance failure is not slippage failure.
* [ ] Avoid runtime ratio comparisons using overflow-prone cross-products; prefer `mulDiv` or test-only bounded comparisons.
* [ ] If upgradeable, preserve storage layout and initialize proxy storage safely.

## 9. Strategy and production considerations

* [ ] Specify how strategy gains, losses, debt, and withdrawals update `totalAssets()`.
* [ ] Bound strategy allocation and external-protocol exposure.
* [ ] Define liquidity behavior when assets are deployed and cannot be withdrawn immediately.
* [ ] Prevent share-price manipulation through stale or externally supplied valuations.
* [ ] Specify management/performance fee calculation, accrual timing, recipients, and rounding.
* [ ] Separate emergency pause behavior for deposits, withdrawals, strategy actions, and governance operations.
* [ ] Preserve an emergency user-exit path where the threat model permits it.
* [ ] Protect privileged roles with least privilege, multisig/timelock controls, and safe rotation.
* [ ] Document supported assets, dependencies, trust assumptions, and known limitations.

## 10. Minimum unit-test matrix

* [ ] Empty-vault deposit mints the expected initial shares.
* [ ] Deposit rounds shares down.
* [ ] Mint rounds required assets up.
* [ ] Withdraw rounds required shares up.
* [ ] Redeem rounds assets down.
* [ ] Positive deposit cannot succeed with zero shares.
* [ ] Positive withdrawal cannot succeed while burning zero shares.
* [ ] Every min/max slippage boundary is tested at equality and one unit beyond it.
* [ ] Direct-donation inflation is unprofitable and cannot zero-mint a protected victim transaction.
* [ ] Fee-on-transfer input is either handled correctly or rejected.
* [ ] Insufficient shares revert before assets leave the vault.
* [ ] Token callback/reentrancy attempts cannot violate accounting.
* [ ] Deposit-then-redeem cannot produce profit without external yield/donations.

## 11. Stateful invariants

* [ ] `totalSupply == sum(actor share balances)` for all handler actors.
* [ ] Ghost-accounted deposits plus donations minus withdrawals equal current vault assets for a standard non-rebasing token.
* [ ] A successful positive withdrawal always burns positive shares.
* [ ] A successful positive deposit always mints positive shares.
* [ ] `sum(convertToAssets(actorShares, Floor)) <= totalAssets()`.
* [ ] Ordinary deposits and withdrawals do not reduce adjusted price per share in a no-loss model.
* [ ] An actor cannot finish with more assets plus redeemable shares than it started with unless assigned external yield/donations.
* [ ] No sequence of valid calls creates assets or shares without a corresponding accounting source.

For ratio comparisons, prefer cross-multiplication only with bounded values or overflow-safe arithmetic:

```text
assetsAfter / supplyAfter >= assetsBefore / supplyBefore

equivalent to

assetsAfter * supplyBefore >= assetsBefore * supplyAfter
```

## NatSpec-ready summary

```solidity
/// @dev Vault accounting requirements:
/// - Conversions use full-precision mulDiv and virtual asset/share liquidity.
/// - Deposit and redeem round down; mint and withdraw round up.
/// - Positive value-moving operations must not produce zero shares/assets.
/// - Deposit uses pre-transfer state and verifies the exact received asset delta.
/// - User entry points enforce operation-specific min/max slippage bounds.
/// - Shares are burned before external asset transfers; token calls are reentrancy-protected.
/// - Direct donations may change share price but must not make inflation attacks profitable.
/// - The supported asset must satisfy the documented transfer and rebase assumptions.
```

## Review rule of thumb

For each vault operation, identify:

1. What value the user fixes.
2. What value the vault calculates.
3. Who receives the rounding remainder.
4. Which state snapshot determines the conversion.
5. Which external call can invalidate the assumptions.
6. Which min/max bound protects the caller.
7. Which invariant proves that value was neither created nor transferred for free.
