# DeFi Protocol Lab

`defi-protocol-lab` is a Solidity and Foundry research workspace for studying how modern DeFi protocols are designed, accounted for, tested, upgraded, and governed.

The project uses deliberately scoped implementations to explore protocol mechanics and security properties without presenting the contracts as production-ready systems.

## Scope

The lab covers interconnected examples across:

- asset/share vaults and fee accounting;
- staking, rebasing tokens, and liquid-staking tokens;
- constant-product and StableSwap-style AMMs;
- on-chain TWAPs, push feeds, signed reports, NAV, and proof-of-reserve oracle adapters;
- lending markets, interest indexes, receipt tokens, liquidations, and bad debt;
- crypto-backed stablecoins;
- tokenized RWA collateral models;
- perpetual-market accounting and risk;
- EIP-712 intents, keepers, partial fills, and fees;
- ERC-4337, EIP-7702, and paymasters;
- UUPS upgrades, transient storage, and namespaced storage;
- governance, timelocks, treasury controls, and DAO proposal execution;
- optional token vesting and distribution mechanics.

## Engineering approach

Each module is developed around the same workflow:

```text
Specification and assumptions
→ equations and rounding rules
→ safety and liveness invariants
→ implementation
→ unit, fuzz, invariant, adversarial, and integration tests
→ threat model and audit-style review
```

The emphasis is on understanding why a design works, where it fails, and how its assumptions interact with other protocol components.

## Shared protocol layers

The modules reuse common concepts rather than operating as unrelated examples:

- the oracle layer supplies normalized price, rate, NAV, reserve, and LST accounting data;
- AMM and oracle mechanics feed lending, stablecoin, RWA, paymaster, and perpetual exercises;
- governance controls selected upgrades, risk parameters, fees, treasury operations, and emergency powers;
- account-abstraction and intent modules orchestrate protocol actions without replacing core accounting checks.

## Project structure

```text
src/       protocol modules and shared primitives
test/      unit, fuzz, invariant, adversarial, and fork tests
script/    deployment, upgrade, and governance scripts
docs/      specifications, invariants, decisions, threat models, and reviews
```

## Current focus

The initial phase focuses on a hardened asset/share vault: conversion mathematics, rounding, inflation resistance, token behaviour, fees, invariant testing, and a controlled UUPS V1-to-V2 upgrade.

The detailed learning sequence and module requirements are maintained in `DEFI_PROTOCOL_LAB_ROADMAP.md`.

## Status

Educational work in progress. Interfaces, assumptions, and implementations may change as individual protocol mechanics are explored and reviewed.
