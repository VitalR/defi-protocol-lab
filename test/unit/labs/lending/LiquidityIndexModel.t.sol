// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { LiquidityIndexModel } from "src/labs/lending/LiquidityIndexModel.sol";

contract LiquidityIndexModelTest is Test {
    LiquidityIndexModel indexModel;

    function setUp() public {
        indexModel = new LiquidityIndexModel();
    }

    function test_constructor_configuration() public {
        assertEq(indexModel.liquidityIndex(), 1e18);
        assertEq(indexModel.lastUpdateTimestamp(), block.timestamp);
    }

    function test_liquidityRate() public {
        assertEq(indexModel.liquidityRate(0.06e18, 0, 0.1e18), 0e18);

        assertEq(indexModel.liquidityRate(0.06e18, 0.8e18, 1e18), 0e18);

        assertEq(indexModel.liquidityRate(0.06e18, 0.8e18, 0.1e18), 0.0432e18);
    }

    function test_liquidityRate_revertsWhenInvalidUtilization() public {
        vm.expectRevert(abi.encodeWithSelector(LiquidityIndexModel.InvalidUtilization.selector, 1.1e18));
        indexModel.liquidityRate(0.06e18, 1.1e18, 0.1e18);
    }

    function test_liquidityRate_revertsWhenInvalidReserveFactor() public {
        vm.expectRevert(abi.encodeWithSelector(LiquidityIndexModel.InvalidReserveFactor.selector, 1.1e18));
        indexModel.liquidityRate(0.06e18, 0.1e18, 1.1e18);
    }

    function test_currentLiquidityIndex() public {
        assertEq(indexModel.liquidityIndex(), 1e18);

        assertEq(indexModel.currentLiquidityIndex(0.06e18, 0.8e18, 0.1e18), 1e18);
    }

    function test_accrue() public {
        assertEq(indexModel.liquidityIndex(), 1e18);
        assertEq(indexModel.currentLiquidityIndex(0.06e18, 0.8e18, 0.1e18), 1e18);

        uint256 currentTimestamp = block.timestamp;

        skip(365 days);
        assertEq(indexModel.currentLiquidityIndex(0.06e18, 0.8e18, 0.1e18), 1.0432e18);

        indexModel.accrue(0.06e18, 0.8e18, 0.1e18);

        assertEq(indexModel.liquidityIndex(), 1.0432e18);
        assertEq(indexModel.lastUpdateTimestamp(), currentTimestamp + 365 days);

        currentTimestamp = block.timestamp;

        skip(365 days);
        assertEq(indexModel.currentLiquidityIndex(0.06e18, 0.8e18, 0.1e18), 1.08826624e18);

        indexModel.accrue(0.06e18, 0.8e18, 0.1e18);

        assertEq(indexModel.liquidityIndex(), 1.08826624e18);
        assertEq(indexModel.lastUpdateTimestamp(), currentTimestamp + 365 days);
    }

    function test_accrue_zeroRateStillCommitsTimestamp() public {
        uint256 initialTimestamp = block.timestamp;

        // Year 1: no utilization => no supplier interest
        skip(365 days);

        indexModel.accrue(0.06e18, 0, 0.1e18);

        assertEq(indexModel.liquidityIndex(), 1e18);
        assertEq(indexModel.lastUpdateTimestamp(), initialTimestamp + 365 days);

        // Year 2: reserve becomes utilized
        skip(365 days);

        assertEq(indexModel.currentLiquidityIndex(0.06e18, 0.8e18, 0.1e18), 1.0432e18);
    }

    function test_accrue_lazy_accrual() public {
        skip(123 days);

        uint256 preview = indexModel.currentLiquidityIndex(0.06e18, 0.8e18, 0.1e18);

        indexModel.accrue(0.06e18, 0.8e18, 0.1e18);

        assertEq(indexModel.liquidityIndex(), preview);
    }
}
