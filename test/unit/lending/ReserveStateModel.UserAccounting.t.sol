// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { ReserveStateModel, Math } from "src/labs/lending/ReserveStateModel.sol";

contract ReserveStateModelUserAccountingTest is Test {
    ReserveStateModel reserveModel;

    address alice = address(0x1001);
    address bob = address(0x1002);

    function setUp() public {
        reserveModel = new ReserveStateModel();
    }

    // Alice borrows before Bob; Bob enters at a higher borrowIndex.
    // Bob does not receive historical debt.
    function test_borrow_user_accounting() public {
        reserveModel.setReserveState(
            0, // totalScaledDebt
            10_000e6, // totalScaledSupply
            10_000e6, // availableLiquidity
            0.02e18, // borrow rate at zero utilization
            0,
            0.1e18
        );

        vm.prank(alice);
        reserveModel.borrow(8000e6);

        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1e18);
        assertEq(state.liquidityIndex, 1e18);
        assertEq(state.accruedToTreasury, 0e6);
        assertEq(state.availableLiquidity, 2000e6);

        assertEq(reserveModel.utilization(), 0.8e18);
        assertEq(reserveModel.borrowRate(), 0.06e18);
        assertEq(reserveModel.liquidityRate(), 0.0432e18);

        assertEq(reserveModel.debtOf(alice), 8000e6);
        assertEq(reserveModel.scaledDebtOf(alice), 8000e6);
        assertEq(reserveModel.currentDebtOf(alice), 8000e6);

        assertEq(reserveModel.totalDebt(), 8000e6);

        skip(365 days);

        vm.prank(bob);
        reserveModel.borrow(500e6);

        state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1.06e18);
        assertEq(state.liquidityIndex, 1.0432e18);
        assertEq(state.accruedToTreasury, 48e6);
        assertEq(state.availableLiquidity, 2000e6 - 500e6);

        assertEq(reserveModel.scaledDebtOf(alice), 8000e6);
        assertEq(reserveModel.debtOf(alice), 8480e6);
        assertEq(reserveModel.currentDebtOf(alice), 8480e6);

        assertEq(reserveModel.scaledDebtOf(bob), 471_698_114);
        assertEq(reserveModel.debtOf(bob), 500_000_001);
        assertEq(reserveModel.currentDebtOf(bob), 500_000_001);

        // totalScaledDebt == Σ scaledDebt[user]
        assertEq(state.totalScaledDebt, reserveModel.scaledDebtOf(alice) + reserveModel.scaledDebtOf(bob));

        uint256 summedUserDebt = reserveModel.debtOf(alice) + reserveModel.debtOf(bob);

        uint256 aggregateDebt = reserveModel.totalDebt();

        assertGe(summedUserDebt, aggregateDebt);
        assertLe(summedUserDebt - aggregateDebt, 1);

        skip(365 days);

        // no borrow action just check params with elapsed time
        assertEq(reserveModel.scaledDebtOf(alice), 8000e6);
        assertEq(reserveModel.debtOf(alice), 8_480_000_000);
        assertEq(reserveModel.currentDebtOf(alice), 10_797_273_283);

        assertEq(reserveModel.scaledDebtOf(bob), 471_698_114);
        assertEq(reserveModel.debtOf(bob), 500_000_001);
        assertEq(reserveModel.currentDebtOf(bob), 636_631_681);

        assertEq(state.totalScaledDebt, reserveModel.scaledDebtOf(alice) + reserveModel.scaledDebtOf(bob));

        // time passed without mutation
        // → individual current debts grew
        // → aggregate current debt grew consistently
        uint256 summedCurrentUserDebt = reserveModel.currentDebtOf(alice) + reserveModel.currentDebtOf(bob);

        uint256 aggregateCurrentDebt = reserveModel.currentTotalDebt();

        assertGe(summedCurrentUserDebt, aggregateCurrentDebt);
        assertLe(summedCurrentUserDebt - aggregateCurrentDebt, 1);
    }

    // Alice full repay removes only Alice's ownership
    // Bob's position remains unchanged
    function test_repay_user_accounting() public {
        _setBalancedReserveWithoutDebt();

        vm.prank(alice);
        reserveModel.borrow(8000e6);

        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1e18);
        assertEq(state.liquidityIndex, 1e18);
        assertEq(state.accruedToTreasury, 0e6);
        assertEq(state.availableLiquidity, 2000e6);

        assertEq(reserveModel.utilization(), 0.8e18);
        assertEq(reserveModel.borrowRate(), 0.06e18);
        assertEq(reserveModel.liquidityRate(), 0.0432e18);

        assertEq(reserveModel.debtOf(alice), 8000e6);
        assertEq(reserveModel.scaledDebtOf(alice), 8000e6);
        assertEq(reserveModel.currentDebtOf(alice), 8000e6);

        assertEq(reserveModel.totalDebt(), 8000e6);

        skip(365 days);

        vm.prank(bob);
        reserveModel.borrow(500e6);

        state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1.06e18);
        assertEq(state.liquidityIndex, 1.0432e18);
        assertEq(state.accruedToTreasury, 48e6);
        assertEq(state.availableLiquidity, 2000e6 - 500e6);

        assertEq(reserveModel.scaledDebtOf(alice), 8000e6);
        assertEq(reserveModel.debtOf(alice), 8480e6);
        assertEq(reserveModel.currentDebtOf(alice), 8480e6);

        assertEq(reserveModel.scaledDebtOf(bob), 471_698_114);
        assertEq(reserveModel.debtOf(bob), 500_000_001);
        assertEq(reserveModel.currentDebtOf(bob), 500_000_001);

        // totalScaledDebt == Σ scaledDebt[user]
        assertEq(state.totalScaledDebt, reserveModel.scaledDebtOf(alice) + reserveModel.scaledDebtOf(bob));

        uint256 summedUserDebt = reserveModel.debtOf(alice) + reserveModel.debtOf(bob);

        uint256 aggregateDebt = reserveModel.totalDebt();

        assertGe(summedUserDebt, aggregateDebt);
        assertLe(summedUserDebt - aggregateDebt, 1);

        // Partial repay
        uint256 aliceScaledBefore = reserveModel.scaledDebtOf(alice);
        uint256 bobScaledBefore = reserveModel.scaledDebtOf(bob);

        uint256 repayAmount = 1000e6;
        uint256 expectedScaledRepay = Math.mulDiv(repayAmount, 1e18, 1.06e18, Math.Rounding.Floor);

        vm.prank(alice);
        reserveModel.repay(repayAmount);

        state = reserveModel.getReserveState();

        assertEq(reserveModel.scaledDebtOf(alice), aliceScaledBefore - expectedScaledRepay);

        assertEq(reserveModel.scaledDebtOf(bob), bobScaledBefore);

        assertEq(state.totalScaledDebt, reserveModel.scaledDebtOf(alice) + reserveModel.scaledDebtOf(bob));

        // Full repay
        uint256 aliceCurrentDebt = reserveModel.currentDebtOf(alice); //8480e6

        vm.prank(alice);
        reserveModel.repay(aliceCurrentDebt);

        // Refresh the memory snapshot after state mutation.
        state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1.06e18);
        assertEq(state.liquidityIndex, 1.0432e18);
        assertEq(state.accruedToTreasury, 48e6);
        assertEq(state.availableLiquidity, 2000e6 - 500e6 + 8480e6 + 1);

        assertEq(reserveModel.scaledDebtOf(alice), 0e6);
        assertEq(reserveModel.debtOf(alice), 0e6);
        assertEq(reserveModel.currentDebtOf(alice), 0e6);

        assertEq(reserveModel.scaledDebtOf(bob), 471_698_114);
        assertEq(reserveModel.debtOf(bob), 500_000_001);
        assertEq(reserveModel.currentDebtOf(bob), 500_000_001);

        assertEq(state.totalScaledDebt, reserveModel.scaledDebtOf(bob));
    }

    // Alice cannot repay more than Alice current debt.
    function test_repay_revertsWhenCurrentDebtExceeded() public {
        _setBalancedReserveWithoutDebt();

        vm.prank(alice);
        reserveModel.borrow(5000e6);

        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1e18);
        assertEq(state.liquidityIndex, 1e18);
        assertEq(state.accruedToTreasury, 0e6);
        assertEq(state.availableLiquidity, 5000e6);

        assertEq(reserveModel.debtOf(alice), 5000e6);
        assertEq(reserveModel.scaledDebtOf(alice), 5000e6);
        assertEq(reserveModel.currentDebtOf(alice), 5000e6);

        assertEq(reserveModel.totalDebt(), 5000e6);

        skip(365 days);

        vm.prank(bob);
        reserveModel.borrow(4000e6);

        state = reserveModel.getReserveState();

        assertEq(state.availableLiquidity, 5000e6 - 4000e6);

        assertEq(reserveModel.scaledDebtOf(alice), 5000e6);
        assertEq(reserveModel.debtOf(alice), 5_225_000_000);
        assertEq(reserveModel.currentDebtOf(alice), 5_225_000_000);

        assertEq(reserveModel.scaledDebtOf(bob), 3_827_751_197);
        assertEq(reserveModel.debtOf(bob), 4_000_000_001);
        assertEq(reserveModel.currentDebtOf(bob), 4_000_000_001);

        // totalScaledDebt == Σ scaledDebt[user]
        assertEq(state.totalScaledDebt, reserveModel.scaledDebtOf(alice) + reserveModel.scaledDebtOf(bob));

        uint256 currentDebt = reserveModel.currentDebtOf(alice);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ReserveStateModel.CurrentDebtExceeded.selector, 5_225_000_001, 5_225_000_000)
        );
        reserveModel.repay(currentDebt + 1);

        assertEq(reserveModel.scaledDebtOf(alice), 5000e6);
        assertEq(reserveModel.debtOf(alice), 5_225_000_000);
        assertEq(reserveModel.currentDebtOf(alice), 5_225_000_000);

        assertEq(reserveModel.scaledDebtOf(bob), 3_827_751_197);
        assertEq(reserveModel.debtOf(bob), 4_000_000_001);
        assertEq(reserveModel.currentDebtOf(bob), 4_000_000_001);

        assertEq(state.totalScaledDebt, reserveModel.scaledDebtOf(alice) + reserveModel.scaledDebtOf(bob));
    }

    function test_repay_revertsWhenDebtReductionTooSmall() public {
        // Alice borrows at index 1.00
        // time passes and index becomes 1.06
        _setBalancedReserveWithoutDebt();

        vm.prank(alice);
        reserveModel.borrow(8000e6);

        skip(365 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReserveStateModel.DebtReductionTooSmall.selector, 1));
        reserveModel.repay(1);
    }

    function _setBalancedReserveWithoutDebt() internal {
        reserveModel.setReserveState(0, 10_000e6, 10_000e6, 0.02e18, 0, 0.1e18);
    }
}
