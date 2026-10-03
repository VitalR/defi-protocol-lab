// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { ScaledSupplyAccounting } from "src/labs/lending/ScaledSupplyAccounting.sol";

contract ScaledSupplyAccountingTest is Test {
    ScaledSupplyAccounting scaledSupplyAccounting;

    address user = address(0x1001);

    function setUp() public {
        scaledSupplyAccounting = new ScaledSupplyAccounting();
    }

    function test_constructor_configuration() public {
        assertEq(scaledSupplyAccounting.liquidityIndex(), 1e18);
    }

    function test_supply() public {
        assertEq(scaledSupplyAccounting.supplyOf(user), 0);
        assertEq(scaledSupplyAccounting.totalScaledSupply(), 0);

        scaledSupplyAccounting.supply(user, 1000e6);

        assertEq(scaledSupplyAccounting.supplyOf(user), 1000e6);
        assertEq(scaledSupplyAccounting.totalScaledSupply(), 1000e6);
    }

    function test_scaledSupplyAccounting_lifecycle() public {
        scaledSupplyAccounting.setLiquidityIndex(1.25e18);

        assertEq(scaledSupplyAccounting.liquidityIndex(), 1.25e18);

        scaledSupplyAccounting.supply(user, 1000e6);

        assertEq(scaledSupplyAccounting.supplyOf(user), 1000e6);
        assertEq(scaledSupplyAccounting.scaledSupplyOf(user), 800e6);
        assertEq(scaledSupplyAccounting.totalScaledSupply(), 800e6);

        scaledSupplyAccounting.setLiquidityIndex(1.4e18);

        assertEq(scaledSupplyAccounting.scaledSupplyOf(user), 800e6);
        assertEq(scaledSupplyAccounting.supplyOf(user), 1120e6);

        assertEq(scaledSupplyAccounting.totalScaledSupply(), 800e6);
        assertEq(scaledSupplyAccounting.totalSupply(), 1120e6);

        scaledSupplyAccounting.withdraw(user, 280e6);

        assertEq(scaledSupplyAccounting.scaledSupplyOf(user), 600e6);
        assertEq(scaledSupplyAccounting.supplyOf(user), 840e6);

        assertEq(scaledSupplyAccounting.totalScaledSupply(), 600e6);
        assertEq(scaledSupplyAccounting.totalSupply(), 840e6);
    }

    function test_supply_revertsWhenZeroAmount() public {
        vm.expectRevert(ScaledSupplyAccounting.ZeroAmount.selector);
        scaledSupplyAccounting.supply(user, 0e6);
    }

    function test_supply_roundsScaledMintDown() public {
        scaledSupplyAccounting.setLiquidityIndex(1.3e18);

        scaledSupplyAccounting.supply(user, 100e6);

        // scaledMint
        // =
        // floor(100e6 / 1.3)
        // =
        // 76,923,076

        // reconstructed claim:
        // 76,923,076 × 1.3
        // =
        // 99,999,998

        // =>
        // claimCreated = 99,999,998
        // deposit      = 100,000,000

        // invariant: claimCreated <= amount

        assertEq(scaledSupplyAccounting.scaledSupplyOf(user), 76_923_076);

        assertLe(scaledSupplyAccounting.supplyOf(user), 100e6);
    }

    function test_supply_revertsWhenSupplyTooSmall() public {
        scaledSupplyAccounting.setLiquidityIndex(1.5e18);

        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyAccounting.SupplyTooSmall.selector, 1));
        scaledSupplyAccounting.supply(user, 1);
    }

    function test_withdraw_roundsScaledBurnUp() public {
        scaledSupplyAccounting.setLiquidityIndex(1.3e18);

        scaledSupplyAccounting.supply(user, 100e6);

        scaledSupplyAccounting.withdraw(user, 50e6);

        // scaledBurn
        // =
        // ceil(50 / 1.3)
        // =
        // 38,461,539

        // supplier claim before = 99,999,998
        // supplier claim after  = 49,999,998

        // invariant: claimBefore - claimAfter >= amountWithdrawn

        // 100 USDC @ index 1.3
        // → scaledMint = 76,923,076

        // 50 USDC withdrawal
        // → scaledBurn = 38,461,539

        // 76,923,076 - 38,461,539 = 38,461,537

        assertEq(scaledSupplyAccounting.scaledSupplyOf(user), 38_461_537);

        assertLe(scaledSupplyAccounting.supplyOf(user), 50e6);
    }

    function test_withdraw_full() public {
        scaledSupplyAccounting.setLiquidityIndex(1.25e18);

        scaledSupplyAccounting.supply(user, 1000e6);

        assertEq(scaledSupplyAccounting.supplyOf(user), 1000e6);
        assertEq(scaledSupplyAccounting.scaledSupplyOf(user), 800e6);
        assertEq(scaledSupplyAccounting.totalScaledSupply(), 800e6);
        assertEq(scaledSupplyAccounting.totalSupply(), 1000e6);

        scaledSupplyAccounting.withdraw(user, 1000e6);

        assertEq(scaledSupplyAccounting.supplyOf(user), 0e6);
        assertEq(scaledSupplyAccounting.scaledSupplyOf(user), 0e6);
        assertEq(scaledSupplyAccounting.totalScaledSupply(), 0e6);
        assertEq(scaledSupplyAccounting.totalSupply(), 0e6);
    }

    function test_withdraw_revertsWhenWithdrawExceedsSupply() public {
        scaledSupplyAccounting.supply(user, 1000e6);

        assertEq(scaledSupplyAccounting.supplyOf(user), 1000e6);
        assertEq(scaledSupplyAccounting.totalScaledSupply(), 1000e6);

        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyAccounting.WithdrawExceedsSupply.selector, 1001e6, 1000e6));
        scaledSupplyAccounting.withdraw(user, 1001e6);
    }

    function test_withdraw_revertsWhenZeroAmount() public {
        vm.expectRevert(ScaledSupplyAccounting.ZeroAmount.selector);
        scaledSupplyAccounting.withdraw(user, 0e6);
    }

    function test_setLiquidityIndex_revertsWhenInvalidIndex() public {
        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyAccounting.InvalidIndex.selector, 0.9e18));
        scaledSupplyAccounting.setLiquidityIndex(0.9e18);
    }

    function test_setLiquidityIndex_revertsWhenIndexCannotDecrease() public {
        assertEq(scaledSupplyAccounting.liquidityIndex(), 1e18);
        scaledSupplyAccounting.setLiquidityIndex(1.25e18);
        assertEq(scaledSupplyAccounting.liquidityIndex(), 1.25e18);

        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyAccounting.IndexCannotDecrease.selector, 1.25e18, 1.24e18));
        scaledSupplyAccounting.setLiquidityIndex(1.24e18);
    }

    function test_totalSupply_trackMultipleUsers() public {
        address user2 = address(0x1002);

        scaledSupplyAccounting.setLiquidityIndex(1.25e18);

        scaledSupplyAccounting.supply(user, 1000e6);
        scaledSupplyAccounting.supply(user2, 500e6);

        assertEq(scaledSupplyAccounting.supplyOf(user), 1000e6);
        assertEq(scaledSupplyAccounting.scaledSupplyOf(user), 800e6);

        assertEq(scaledSupplyAccounting.supplyOf(user2), 500e6);
        assertEq(scaledSupplyAccounting.scaledSupplyOf(user2), 400e6);

        assertEq(scaledSupplyAccounting.totalScaledSupply(), 1200e6);
        assertEq(scaledSupplyAccounting.totalSupply(), 1500e6);

        scaledSupplyAccounting.setLiquidityIndex(1.4e18);

        assertEq(scaledSupplyAccounting.totalScaledSupply(), 1200e6);
        assertEq(scaledSupplyAccounting.totalSupply(), 1680e6);
    }
}
