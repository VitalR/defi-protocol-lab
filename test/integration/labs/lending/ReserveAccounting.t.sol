// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { ReserveFactorAccounting } from "src/labs/lending/ReserveFactorAccounting.sol";
import { InterestIndexModel } from "src/labs/lending/InterestIndexModel.sol";
import { LiquidityIndexModel } from "src/labs/lending/LiquidityIndexModel.sol";
import { ScaledSupplyAccounting } from "src/labs/lending/ScaledSupplyAccounting.sol";
import { ScaledDebtAccounting } from "src/labs/lending/ScaledDebtAccounting.sol";

contract ReserveAccountingTest is Test {
    LiquidityIndexModel liquidityModel;
    InterestIndexModel borrowModel;
    ScaledSupplyAccounting supplyAccounting;
    ScaledDebtAccounting debtAccounting;
    ReserveFactorAccounting treasuryAccounting;

    address user = address(0x1001);

    function setUp() public {
        liquidityModel = new LiquidityIndexModel();
        borrowModel = new InterestIndexModel();
        supplyAccounting = new ScaledSupplyAccounting();
        debtAccounting = new ScaledDebtAccounting();
        treasuryAccounting = new ReserveFactorAccounting();
    }

    function test_reserve_level_balance_sheet() public {
        // Suppliers:          10,000 USDC
        // Borrowed:            8,000 USDC
        // Available:           2,000 USDC

        // Utilization:           80%
        // Borrow rate:             6%
        // Reserve factor:         10%
        // Liquidity rate:       4.32%

        assertEq(supplyAccounting.supplyOf(user), 0);
        assertEq(supplyAccounting.totalScaledSupply(), 0);

        uint256 supplyAmount = 10_000e6;

        supplyAccounting.supply(user, supplyAmount);

        assertEq(supplyAccounting.totalScaledSupply(), supplyAmount);
        assertEq(supplyAccounting.totalSupply(), supplyAmount);

        uint256 borrowAmount = 8000e6;

        debtAccounting.addDebt(user, borrowAmount);

        assertEq(debtAccounting.totalDebt(), borrowAmount);

        assertEq(treasuryAccounting.accruedToTreasury(), 0);

        uint256 currentTimestamp = block.timestamp;
        uint256 reserveFactor = 0.1e18;

        skip(365 days);
        // After year
        // Debt:
        // 8,000 → 8,480
        // borrow interest = 480

        // Supplier claims:
        // 10,000 → 10,432
        // supplier interest = 432

        // Treasury:
        // 0 → 48
        liquidityModel.accrue(0.06e18, 0.8e18, reserveFactor);
        uint256 newIndex = liquidityModel.liquidityIndex(); //liquidityModel.currentLiquidityIndex(0.06e18, 0.8e18,
        // reserveFactor);
        supplyAccounting.setLiquidityIndex(newIndex); //1.0432e18

        uint256 borrowIndex = borrowModel.previewBorrowIndex(0.06e18, currentTimestamp + 365 days);
        borrowModel.updateBorrowIndex(0.06e18);
        debtAccounting.setBorrowIndex(borrowIndex);

        uint256 actualDebt = debtAccounting.totalDebt(); //borrowModel.fromScaledDebt(8000e6, borrowIndex);

        uint256 borrowInterest = actualDebt - borrowAmount;

        uint256 supplierClaims = supplyAccounting.totalSupply();
        uint256 supplierInterest = supplierClaims - supplyAmount;

        uint256 treasuryAccrual = treasuryAccounting.accrueTreasury(borrowInterest, reserveFactor);
        assertEq(treasuryAccounting.accruedToTreasury(), treasuryAccrual);

        // Main invariant:
        //
        // borrowInterest
        // ==
        // supplierInterest + treasuryAccrual
        //
        // 480 = 432 + 48
        assertEq(borrowInterest, supplierInterest + treasuryAccrual);

        // Balance sheet:

        // Assets:
        // available liquidity     2,000
        // borrower debt           8,480
        //                     ------
        //                     10,480

        // Claims:
        // supplier claims        10,432
        // treasury claim             48
        //                     ------
        //                     10,480

        uint256 availableLiquidity = supplyAmount - borrowAmount;

        uint256 reserveAssets = availableLiquidity + actualDebt;

        uint256 reserveClaims = supplierClaims + treasuryAccounting.accruedToTreasury();

        assertEq(reserveAssets, reserveClaims);
    }
}
