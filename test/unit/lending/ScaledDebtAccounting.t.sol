// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { ScaledDebtAccounting } from "src/labs/lending/ScaledDebtAccounting.sol";

contract ScaledDebtAccountingTest is Test {
    ScaledDebtAccounting scaledDebtAccounting;

    address user = address(0x1001);

    function setUp() public {
        scaledDebtAccounting = new ScaledDebtAccounting();
    }

    function test_constructor_configuration() public {
        assertEq(scaledDebtAccounting.borrowIndex(), 1e18);
    }

    function test_addDebt() public {
        assertEq(scaledDebtAccounting.borrowIndex(), 1e18);

        scaledDebtAccounting.addDebt(user, 1000e6);

        assertEq(scaledDebtAccounting.debtOf(user), 1000e6);

        assertEq(scaledDebtAccounting.scaledDebtOf(user), 1000e6);
    }

    function test_scaledDebtAccountingLifecycle() public {
        scaledDebtAccounting.setBorrowIndex(1.25e18);

        assertEq(scaledDebtAccounting.borrowIndex(), 1.25e18);

        scaledDebtAccounting.addDebt(user, 1000e6);

        assertEq(scaledDebtAccounting.debtOf(user), 1000e6);

        assertEq(scaledDebtAccounting.scaledDebtOf(user), 800e6);

        assertEq(scaledDebtAccounting.totalScaledDebt(), 800e6);

        // index growth changes actual debt but not scaled debt
        scaledDebtAccounting.setBorrowIndex(1.4e18);

        // storage unchanged
        assertEq(scaledDebtAccounting.scaledDebtOf(user), 800e6);
        // economic debt grows
        assertEq(scaledDebtAccounting.debtOf(user), 1120e6);

        assertEq(scaledDebtAccounting.totalScaledDebt(), 800e6);
        assertEq(scaledDebtAccounting.totalDebt(), 1120e6);

        // partial repay reduces scaled debt correctly
        scaledDebtAccounting.repayDebt(user, 280e6);

        assertEq(scaledDebtAccounting.scaledDebtOf(user), 600e6);
        assertEq(scaledDebtAccounting.debtOf(user), 840e6);

        assertEq(scaledDebtAccounting.totalScaledDebt(), 600e6);
        assertEq(scaledDebtAccounting.totalDebt(), 840e6);
    }

    function test_addDebt_revertsWhenZeroAmount() public {
        vm.expectRevert(ScaledDebtAccounting.ZeroAmount.selector);
        scaledDebtAccounting.addDebt(user, 0e6);
    }

    function test_repayDebt_full() public {
        scaledDebtAccounting.setBorrowIndex(1.25e18);

        scaledDebtAccounting.addDebt(user, 1000e6);

        assertEq(scaledDebtAccounting.debtOf(user), 1000e6);
        assertEq(scaledDebtAccounting.scaledDebtOf(user), 800e6);

        assertEq(scaledDebtAccounting.totalScaledDebt(), 800e6);
        assertEq(scaledDebtAccounting.totalDebt(), 1000e6);

        scaledDebtAccounting.repayDebt(user, 1000e6);

        assertEq(scaledDebtAccounting.debtOf(user), 0e6);
        assertEq(scaledDebtAccounting.scaledDebtOf(user), 0e6);

        assertEq(scaledDebtAccounting.totalScaledDebt(), 0);
        assertEq(scaledDebtAccounting.totalDebt(), 0);
    }

    function test_repayDebt_revertsWhenRepayExceedsDebt() public {
        scaledDebtAccounting.addDebt(user, 1000e6);

        assertEq(scaledDebtAccounting.debtOf(user), 1000e6);
        assertEq(scaledDebtAccounting.scaledDebtOf(user), 1000e6);

        vm.expectRevert(abi.encodeWithSelector(ScaledDebtAccounting.RepayExceedsDebt.selector, 1001e6, 1000e6));
        scaledDebtAccounting.repayDebt(user, 1001e6);
    }

    function test_repayDebt_revertsWhenZeroAmount() public {
        vm.expectRevert(ScaledDebtAccounting.ZeroAmount.selector);
        scaledDebtAccounting.repayDebt(user, 0e6);
    }

    function test_repayDebt_revertsWhenRepayTooSmall() public {
        scaledDebtAccounting.addDebt(user, 1000e6);

        scaledDebtAccounting.setBorrowIndex(1.4e18);

        // amount × 1e18 < borrowIndex
        // eg borrowIndex = 1.4e18
        // and amount = 1
        // =>
        // 1 × 1e18 / 1.4e18
        // = 0.714...
        // → Floor = 0
        vm.expectRevert(abi.encodeWithSelector(ScaledDebtAccounting.RepayTooSmall.selector, 1));
        scaledDebtAccounting.repayDebt(user, 1);
    }

    function test_setBorrowIndex_revertsWhenInvalidIndex() public {
        vm.expectRevert(abi.encodeWithSelector(ScaledDebtAccounting.InvalidIndex.selector, 0.9e18));
        scaledDebtAccounting.setBorrowIndex(0.9e18);
    }

    function test_setBorrowIndex_revertsWhenIndexCannotDecrease() public {
        assertEq(scaledDebtAccounting.borrowIndex(), 1e18);
        scaledDebtAccounting.setBorrowIndex(1.25e18);
        assertEq(scaledDebtAccounting.borrowIndex(), 1.25e18);

        vm.expectRevert(abi.encodeWithSelector(ScaledDebtAccounting.IndexCannotDecrease.selector, 1.25e18, 1.24e18));
        scaledDebtAccounting.setBorrowIndex(1.24e18);
    }

    // index changes
    // → no borrower iteration
    // → no totalScaledDebt mutation
    // → total economic debt still grows
    function test_totalDebt_tracksMultipleUsers() public {
        address user2 = address(0x1002);

        scaledDebtAccounting.setBorrowIndex(1.25e18);

        scaledDebtAccounting.addDebt(user, 1000e6);
        scaledDebtAccounting.addDebt(user2, 500e6);

        assertEq(scaledDebtAccounting.scaledDebtOf(user), 800e6);

        assertEq(scaledDebtAccounting.scaledDebtOf(user2), 400e6);

        assertEq(scaledDebtAccounting.totalScaledDebt(), 1200e6);

        assertEq(scaledDebtAccounting.totalDebt(), 1500e6);

        scaledDebtAccounting.setBorrowIndex(1.4e18);

        assertEq(scaledDebtAccounting.totalScaledDebt(), 1200e6);

        assertEq(scaledDebtAccounting.totalDebt(), 1680e6);
    }
}
