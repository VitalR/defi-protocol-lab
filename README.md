## DeFi-LEGO

**Modular Framework for Composable Yield & Leverage Strategies**


## Overview

DeFi-LEGO is an evolving on-chain framework for designing, testing, and deploying modular DeFi strategies.
It currently integrates Aave V3 and Uniswap V3, with upcoming support for additional lending and liquidity protocols.

Each module acts as a self-contained “building block” — enabling developers to experiment with leveraged positions, flash loans, liquidation mechanics, and cross-protocol yield flows.


## Current Modules
- AaveV3MultiAssetStrategy — Base multi-asset supply/borrow strategy.
- LeveragePositionManager — Opens and closes leveraged long/short positions via Aave V3 + Uniswap V3.
- FlashLoanExecutor — Minimal flash-loan receiver for arbitrage or deleveraging.
- LiquidationPlayground — Sandbox for liquidation simulations and testing.
- TokenActions — Safe ERC-20 helper library for transfers and approvals.


### Scripts
- Foundry scripts mirror live DeFi flows such as:
- Supplying assets and borrowing collateral.
- Opening or closing leveraged positions.
- Simulating liquidation and repayment scenarios.
- Executing flash-loan and rebalancing operations.                                  |

<hr>

### Vision
DeFi-LEGO aims to become a protocol-agnostic toolkit for building secure, modular DeFi infrastructure —
from strategy orchestration to multi-protocol leverage and cross-chain automation.
