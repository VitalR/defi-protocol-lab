// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { ReserveStateModel, Math } from "src/labs/lending/ReserveStateModel.sol";

contract ReserveStateModelUserAccountingTest is Test {
    ReserveStateModel reserveModel;

    address alice = address(0x1001);
    address bob = address(0x1002);
    address borrower = address(0x1003);

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

    // Alice supplies before Bob; Bob enters at a higher liquidityIndex.
    // Bob does not receive Alice's historical yield.
    function test_supply_user_accounting() public {
        reserveModel.setReserveState(
            0, // totalScaledDebt
            0, // totalScaledSupply
            0, // availableLiquidity
            0.02e18,
            0,
            0.1e18
        );

        vm.prank(alice);
        reserveModel.supply(10_000e6);

        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();

        assertEq(state.availableLiquidity, 10_000e6);
        assertEq(state.totalScaledSupply, 10_000e6);
        assertEq(reserveModel.supplyOf(alice), 10_000e6);
        assertEq(reserveModel.scaledSupplyOf(alice), 10_000e6);

        vm.prank(borrower);
        reserveModel.borrow(8000e6);

        state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1e18);
        assertEq(state.liquidityIndex, 1e18);
        assertEq(state.accruedToTreasury, 0e6);
        assertEq(state.availableLiquidity, 2000e6);

        assertEq(reserveModel.utilization(), 0.8e18);
        assertEq(reserveModel.borrowRate(), 0.06e18);
        assertEq(reserveModel.liquidityRate(), 0.0432e18);

        skip(365 days);

        vm.prank(bob);
        reserveModel.supply(500e6);

        state = reserveModel.getReserveState();

        assertEq(reserveModel.scaledSupplyOf(alice), 10_000e6);
        assertEq(reserveModel.currentSupplyOf(alice), 10_432e6);

        assertEq(reserveModel.scaledSupplyOf(bob), 479_294_478);
        assertEq(reserveModel.supplyOf(bob), 499_999_999);
        assertEq(reserveModel.currentSupplyOf(bob), 499_999_999);
        assertLt(reserveModel.supplyOf(bob), 500e6);

        assertEq(state.totalScaledSupply, reserveModel.scaledSupplyOf(alice) + reserveModel.scaledSupplyOf(bob));

        uint256 summedUserSupply = reserveModel.supplyOf(alice) + reserveModel.supplyOf(bob);
        uint256 aggregateSupply = reserveModel.totalSupply();

        assertLe(summedUserSupply, aggregateSupply);
        assertLe(aggregateSupply - summedUserSupply, 1);

        // one more year past - current supply without mutation
        uint256 aliceStoredSupply = reserveModel.supplyOf(alice);
        uint256 bobStoredSupply = reserveModel.supplyOf(bob);

        skip(365 days);

        assertEq(reserveModel.supplyOf(alice), aliceStoredSupply);
        assertEq(reserveModel.supplyOf(bob), bobStoredSupply);

        assertGt(reserveModel.currentSupplyOf(alice), aliceStoredSupply);
        assertGt(reserveModel.currentSupplyOf(bob), bobStoredSupply);

        // Σ floor(user claims)
        // <=
        // floor(Σ scaled supply × index)
        uint256 summedCurrentSupply = reserveModel.currentSupplyOf(alice) + reserveModel.currentSupplyOf(bob);
        uint256 aggregateCurrentSupply = reserveModel.currentTotalSupply();

        assertLe(summedCurrentSupply, aggregateCurrentSupply);
        assertLe(aggregateCurrentSupply - summedCurrentSupply, 1);
    }

    function test_withdraw_partial() public {
        reserveModel.setReserveState(0, 0, 0, 0.02e18, 0, 0.1e18);

        vm.prank(alice);
        reserveModel.supply(10_000e6);

        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();

        assertEq(state.availableLiquidity, 10_000e6);
        assertEq(state.totalScaledSupply, 10_000e6);
        assertEq(reserveModel.supplyOf(alice), 10_000e6);
        assertEq(reserveModel.scaledSupplyOf(alice), 10_000e6);

        vm.prank(borrower);
        reserveModel.borrow(8000e6);

        state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1e18);
        assertEq(state.liquidityIndex, 1e18);
        assertEq(state.accruedToTreasury, 0e6);
        assertEq(state.availableLiquidity, 2000e6);

        assertEq(reserveModel.utilization(), 0.8e18);
        assertEq(reserveModel.borrowRate(), 0.06e18);
        assertEq(reserveModel.liquidityRate(), 0.0432e18);

        skip(365 days);

        vm.prank(bob);
        reserveModel.supply(500e6);

        state = reserveModel.getReserveState();

        assertEq(state.availableLiquidity, 2500e6);

        uint256 aliceScaledBefore = reserveModel.scaledSupplyOf(alice);
        uint256 bobScaledBefore = reserveModel.scaledSupplyOf(bob);

        uint256 withdrawAmount = 1000e6;

        uint256 expectedScaledBurn = Math.mulDiv(withdrawAmount, 1e18, state.liquidityIndex, Math.Rounding.Ceil);

        vm.prank(alice);
        reserveModel.withdraw(withdrawAmount);

        state = reserveModel.getReserveState();

        assertEq(reserveModel.scaledSupplyOf(alice), aliceScaledBefore - expectedScaledBurn);

        assertEq(reserveModel.scaledSupplyOf(bob), bobScaledBefore);

        assertEq(state.totalScaledSupply, reserveModel.scaledSupplyOf(alice) + reserveModel.scaledSupplyOf(bob));

        assertEq(state.availableLiquidity, 1500e6);
    }

    function test_withdraw_full() public {
        reserveModel.setReserveState(0, 0, 0, 0.02e18, 0, 0.1e18);

        vm.prank(alice);
        reserveModel.supply(10_000e6);

        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();

        assertEq(state.availableLiquidity, 10_000e6);
        assertEq(state.totalScaledSupply, 10_000e6);
        assertEq(reserveModel.supplyOf(alice), 10_000e6);
        assertEq(reserveModel.scaledSupplyOf(alice), 10_000e6);

        vm.prank(borrower);
        reserveModel.borrow(8000e6);

        state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1e18);
        assertEq(state.liquidityIndex, 1e18);
        assertEq(state.accruedToTreasury, 0e6);
        assertEq(state.availableLiquidity, 2000e6);

        assertEq(reserveModel.utilization(), 0.8e18);
        assertEq(reserveModel.borrowRate(), 0.06e18);
        assertEq(reserveModel.liquidityRate(), 0.0432e18);

        skip(365 days);

        vm.prank(bob);
        reserveModel.supply(500e6);

        state = reserveModel.getReserveState();

        assertEq(reserveModel.scaledSupplyOf(alice), 10_000e6);
        assertEq(reserveModel.currentSupplyOf(alice), 10_432e6);

        assertEq(reserveModel.scaledSupplyOf(bob), 479_294_478);

        assertEq(state.totalScaledSupply, reserveModel.scaledSupplyOf(alice) + reserveModel.scaledSupplyOf(bob));

        uint256 summedUserSupply = reserveModel.supplyOf(alice) + reserveModel.supplyOf(bob);
        uint256 aggregateSupply = reserveModel.totalSupply();

        assertLe(summedUserSupply, aggregateSupply);
        assertLe(aggregateSupply - summedUserSupply, 1);

        uint256 currentWithdrawableAlice = reserveModel.currentSupplyOf(alice);
        assertGt(currentWithdrawableAlice, state.availableLiquidity);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ReserveStateModel.InsufficientLiquidity.selector, 10_432_000_000, 2_500_000_000)
        );
        reserveModel.withdraw(currentWithdrawableAlice);

        uint256 borrowerDebt = reserveModel.currentDebtOf(borrower);

        vm.prank(borrower);
        reserveModel.repay(borrowerDebt);

        uint256 aliceClaim = reserveModel.currentSupplyOf(alice);

        vm.prank(alice);
        reserveModel.withdraw(aliceClaim);

        state = reserveModel.getReserveState();

        assertEq(reserveModel.scaledSupplyOf(alice), 0e6);
        assertEq(reserveModel.scaledSupplyOf(bob), 479_294_478);
        assertEq(state.totalScaledSupply, 479_294_478);

        assertEq(reserveModel.supplyOf(bob), 499_999_999);

        assertEq(reserveModel.totalSupply(), 499_999_999);

        // Bob claim          = 499,999,999
        // treasury claim     =  48,000,000
        // rounding surplus   =           1
        //                     -----------
        // available          = 548,000,000
        //
        // Bob claim + treasury accrual + 1 unit rounding surplus.
        assertEq(state.availableLiquidity, 548_000_000);
    }

    function test_withdraw_revertsWhenUserSupplyExceeded() public {
        reserveModel.setReserveState(0, 0, 0, 0.02e18, 0, 0.1e18);

        vm.prank(alice);
        reserveModel.supply(100e6);

        vm.prank(bob);
        reserveModel.supply(9900e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReserveStateModel.WithdrawExceedsSupply.selector, 101e6, 100e6));
        reserveModel.withdraw(101e6);
    }
}
