// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { LiquidityIndexModel } from "src/labs/lending/LiquidityIndexModel.sol";
import { ScaledSupplyAccounting } from "src/labs/lending/ScaledSupplyAccounting.sol";

contract SupplierInterestAccountingTest is Test {
    LiquidityIndexModel liquidityModel;
    ScaledSupplyAccounting supplyAccounting;

    address user = address(0x1001);
    address user2 = address(0x1002);

    function setUp() public {
        liquidityModel = new LiquidityIndexModel();
        supplyAccounting = new ScaledSupplyAccounting();
    }

    function test_supplier_claim_grows_via_liquidity_index() public {
        assertEq(supplyAccounting.supplyOf(user), 0);
        assertEq(supplyAccounting.totalScaledSupply(), 0);

        supplyAccounting.supply(user, 10_000e6);

        assertEq(supplyAccounting.totalScaledSupply(), 10_000e6);
        assertEq(supplyAccounting.totalSupply(), 10_000e6);

        assertEq(liquidityModel.currentLiquidityIndex(0.06e18, 0.8e18, 0.1e18), 1e18);

        uint256 scaledBefore = supplyAccounting.totalScaledSupply();
        uint256 initialSupply = supplyAccounting.totalSupply();

        skip(365 days);
        assertEq(liquidityModel.currentLiquidityIndex(0.06e18, 0.8e18, 0.1e18), 1.0432e18);

        uint256 newIndex = liquidityModel.currentLiquidityIndex(0.06e18, 0.8e18, 0.1e18);

        liquidityModel.accrue(0.06e18, 0.8e18, 0.1e18);

        supplyAccounting.setLiquidityIndex(newIndex); //1.0432e18

        // scaled supply stays constant while time passes
        assertEq(supplyAccounting.totalScaledSupply(), scaledBefore);
        assertEq(supplyAccounting.totalScaledSupply(), 10_000e6);

        // actual supply increases
        assertGt(supplyAccounting.totalSupply(), initialSupply);
        assertEq(supplyAccounting.totalSupply(), 10_432e6);
    }

    function test_scaled_supply_does_not_change_from_interest_accrual() public {
        // totalScaledSupply unchanged

        supplyAccounting.supply(user, 10_000e6);

        assertEq(supplyAccounting.scaledSupplyOf(user), 10_000e6);
        assertEq(supplyAccounting.supplyOf(user), 10_000e6);

        skip(365 days);
        assertEq(liquidityModel.currentLiquidityIndex(0.06e18, 0.8e18, 0.1e18), 1.0432e18);
        uint256 newIndex = liquidityModel.currentLiquidityIndex(0.06e18, 0.8e18, 0.1e18);
        supplyAccounting.setLiquidityIndex(newIndex); //1.0432e18

        assertEq(supplyAccounting.scaledSupplyOf(user), 10_000e6);
        assertEq(supplyAccounting.supplyOf(user), 10_432e6);

        supplyAccounting.supply(user2, 1043.2e6);

        assertEq(supplyAccounting.scaledSupplyOf(user2), 1000e6);
        assertEq(supplyAccounting.supplyOf(user2), 1_043_200_000);
    }

    function test_new_supplier_does_not_receive_historical_yield() public {
        assertEq(supplyAccounting.liquidityIndex(), 1e18);
        assertEq(liquidityModel.liquidityIndex(), 1e18);

        supplyAccounting.supply(user, 1000e6);

        skip(365 days);
        liquidityModel.accrue(0.06e18, 0.8e18, 0.1e18);
        uint256 newIndex = liquidityModel.currentLiquidityIndex(0.06e18, 0.8e18, 0.1e18);
        supplyAccounting.setLiquidityIndex(newIndex); //1.0432e18

        assertEq(supplyAccounting.scaledSupplyOf(user), 1000e6);
        assertEq(supplyAccounting.supplyOf(user), 1_043_200_000);

        // new supplier converts at current index
        supplyAccounting.supply(user2, 1043.2e6);

        // historical yield is not granted
        assertEq(supplyAccounting.scaledSupplyOf(user2), 1000e6);
        assertEq(supplyAccounting.supplyOf(user2), 1_043_200_000);

        skip(365 days);
        liquidityModel.accrue(0.06e18, 0.8e18, 0.1e18);
        newIndex = liquidityModel.currentLiquidityIndex(0.06e18, 0.8e18, 0.1e18);
        supplyAccounting.setLiquidityIndex(newIndex); //1.08826624e18

        // future accrual is fair
        assertEq(supplyAccounting.supplyOf(user), 1088.26624e6);
        assertEq(supplyAccounting.supplyOf(user2), 1088.26624e6);
    }
}
