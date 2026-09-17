// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { ReserveStateModel, Math } from "src/labs/lending/ReserveStateModel.sol";

contract ReserveStateModelTest is Test {
    ReserveStateModel reserveModel;

    address user = address(0x1001);

    function setUp() public {
        reserveModel = new ReserveStateModel();
    }

    function test_constructor_configuration() public {
        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();
        assertEq(state.borrowIndex, 1e18);
        assertEq(state.liquidityIndex, 1e18);
        assertEq(state.totalScaledDebt, 0);
        assertEq(state.totalScaledSupply, 0);
        assertEq(state.availableLiquidity, 0);
        assertEq(state.accruedToTreasury, 0);
        assertEq(state.currentBorrowRate, 0);
        assertEq(state.currentLiquidityRate, 0);
        assertEq(state.reserveFactor, 0.1e18);
        assertEq(state.lastUpdateTimestamp, block.timestamp);
    }

    function test_accrueReserve_lifecycle() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);

        uint256 currentTimestamp = block.timestamp;

        skip(365 days);

        reserveModel.accrueReserve();

        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();
        assertEq(state.borrowIndex, 1.06e18);
        assertEq(state.liquidityIndex, 1.0432e18);
        assertEq(state.totalScaledDebt, 8000e6);
        assertEq(state.totalScaledSupply, 10_000e6);
        assertEq(state.availableLiquidity, 2000e6);
        assertEq(state.accruedToTreasury, 48e6);
        assertEq(state.lastUpdateTimestamp, currentTimestamp + 365 days);

        // Balance sheet verification
        //
        // Assets:
        // availableLiquidity + totalDebt
        // =
        // 2,000 + 8,480
        // =
        // 10,480
        uint256 availableLiquidity = state.availableLiquidity;
        uint256 debt = reserveModel.totalDebt();
        assertEq(availableLiquidity + debt, 10_480e6);

        // Claims:
        // totalSupply + accruedToTreasury
        // =
        // 10,432 + 48
        // =
        // 10,480
        assertEq(
            state.availableLiquidity + reserveModel.totalDebt(), reserveModel.totalSupply() + state.accruedToTreasury
        );
    }

    function test_accrueReserve_zeroRateStillCommitsTimestamp() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0, 0, 0.1e18);

        uint256 start = block.timestamp;

        skip(365 days);
        reserveModel.accrueReserve();

        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1e18);
        assertEq(state.liquidityIndex, 1e18);
        assertEq(state.lastUpdateTimestamp, start + 365 days);

        reserveModel.updateRates(0.06e18, 0.0432e18);

        skip(365 days);
        reserveModel.accrueReserve();

        state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1.06e18);
        assertEq(state.liquidityIndex, 1.0432e18);
    }

    function test_borrow() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);

        uint256 start = block.timestamp;

        skip(365 days);

        reserveModel.borrow(1000e6);

        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1.06e18);
        assertEq(state.liquidityIndex, 1.0432e18);
        assertEq(state.accruedToTreasury, 48e6);
        assertEq(state.availableLiquidity, 1000e6);

        assertEq(reserveModel.totalDebt(), 9_480_000_001);
        assertEq(reserveModel.utilization(), 904_580_152_680_860_672);

        assertGt(reserveModel.borrowRate(), 0.06e18);
        assertGt(reserveModel.liquidityRate(), 0.0432e18);
    }

    function test_borrow_second_interval_accrues_using_rateAfterBorrow() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);

        uint256 start = block.timestamp;

        skip(365 days);

        reserveModel.borrow(1000e6);

        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1.06e18);
        assertEq(state.liquidityIndex, 1.0432e18);
        assertEq(state.accruedToTreasury, 48e6);
        assertEq(state.availableLiquidity, 1000e6);

        assertEq(reserveModel.totalDebt(), 9_480_000_001);
        assertEq(reserveModel.utilization(), 904_580_152_680_860_672);

        assertGt(reserveModel.borrowRate(), 0.06e18);
        assertGt(reserveModel.liquidityRate(), 0.0432e18);

        state = reserveModel.getReserveState();

        uint256 rateAfterBorrow = state.currentBorrowRate;
        uint256 borrowIndexBeforeSecondInterval = state.borrowIndex;

        uint256 expectedGrowth = Math.mulDiv(borrowIndexBeforeSecondInterval, rateAfterBorrow, 1e18, Math.Rounding.Ceil);

        uint256 expectedBorrowIndex = borrowIndexBeforeSecondInterval + expectedGrowth;

        skip(365 days);
        reserveModel.accrueReserve();

        state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, expectedBorrowIndex);

        assertEq(reserveModel.totalDebt(), 13_766_624_429);
        assertEq(reserveModel.utilization(), 932_279_716_003_603_926);
    }
}
