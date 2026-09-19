// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { ReserveStateModel, Math } from "src/labs/lending/ReserveStateModel.sol";

// Reserve Lifecycle:

// accrue old interval
//         ↓
// commit indexes + treasury
//         ↓
// perform action
//         ↓
// new debt/liquidity state
//         ↓
// new utilization
//         ↓
// store rates for next interval

// Supply   → available ↑ → U ↓ → rates ↓
// Withdraw → available ↓ → U ↑ → rates ↑

// Borrow   → debt ↑ + available ↓ → U ↑ → rates ↑
// Repay    → debt ↓ + available ↑ → U ↓ → rates ↓

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

    function test_repay() public {
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

        reserveModel.repay(500e6);

        state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1.06e18);
        assertEq(state.liquidityIndex, 1.0432e18);
        assertEq(state.accruedToTreasury, 48e6);
        assertEq(state.availableLiquidity, 1500e6);

        assertEq(reserveModel.totalDebt(), 8_980_000_001);
        assertEq(reserveModel.utilization(), 856_870_229_021_291_008);

        assertEq(reserveModel.borrowRate(), 273_263_358_829_841_280); //BorrowRate: ~ 27.3263%
        assertEq(reserveModel.liquidityRate(), 210_736_113_177_287_988); //Liquidity rate: ~ 21.07%

        skip(365 days);

        assertLt(reserveModel.totalDebt(), reserveModel.currentTotalDebt());

        uint256 repayFullAmount = reserveModel.currentTotalDebt();

        reserveModel.repay(repayFullAmount);

        state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1_349_659_160_359_631_757);
        assertEq(state.liquidityIndex, 1_263_039_913_266_546_829);

        // 48
        // +
        // 245.390496
        // =
        // 293.390496 USDC
        assertEq(state.accruedToTreasury, 293_390_496);

        // 1,500
        // +
        // 11,433.904962
        // =
        // 12,933.904962 USDC
        assertEq(state.availableLiquidity, 12_933_904_964);

        assertEq(state.currentBorrowRate, reserveModel.BASE_RATE());
        assertEq(state.currentLiquidityRate, 0);

        assertEq(reserveModel.totalDebt(), 0);
        assertEq(reserveModel.utilization(), 0);

        // 8000 initial debt
        // → +480 interest
        // → +1000 new borrow
        // = 9480

        // → -500 partial repay
        // = 8980

        // → +2453.904962 second-year interest
        // = 11433.904962

        // → full repay
        // = 0
    }

    function test_supply() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);

        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1e18);
        assertEq(state.liquidityIndex, 1e18);
        assertEq(state.accruedToTreasury, 0);
        assertEq(state.availableLiquidity, 2000e6);

        assertEq(reserveModel.totalDebt(), 8000e6);
        assertEq(reserveModel.utilization(), 0.8e18);

        assertEq(reserveModel.borrowRate(), 0.06e18);
        assertEq(reserveModel.liquidityRate(), 0.0432e18);

        assertEq(reserveModel.totalSupply(), 10_000e6);

        skip(365 days);

        assertLt(reserveModel.totalSupply(), reserveModel.currentTotalSupply());

        reserveModel.supply(1000e6);

        state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1.06e18);
        assertEq(state.liquidityIndex, 1.0432e18);
        assertEq(state.accruedToTreasury, 48e6);
        assertEq(state.availableLiquidity, 3000e6);

        assertEq(reserveModel.totalDebt(), 8_480_000_000);

        // debt      = 8480
        // available = 3000

        // U =
        // 8480 / 11480
        // ≈ 73.8676%
        assertEq(reserveModel.utilization(), 738_675_958_188_153_310);

        assertLt(reserveModel.borrowRate(), 0.06e18);
        assertLt(reserveModel.liquidityRate(), 0.0432e18);

        // old suppliers: 10,432
        // new supplier:  ~1,000

        // total:
        // ~11,432
        assertEq(reserveModel.totalSupply(), 11_431_999_999); //-1 native unit Floor rounding effect
        assertEq(reserveModel.totalSupply(), reserveModel.currentTotalSupply());

        reserveModel.supply(5000e6);

        state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1.06e18);
        assertEq(state.liquidityIndex, 1.0432e18);
        assertEq(state.accruedToTreasury, 48e6);
        assertEq(state.availableLiquidity, 8000e6);

        assertEq(reserveModel.totalDebt(), 8_480_000_000);
        assertEq(reserveModel.utilization(), 514_563_106_796_116_504); // U ~ 51% significantly decrease =>

        assertEq(reserveModel.borrowRate(), 45_728_155_339_805_825); //BorrowRate: ~ 4.572%
        assertEq(reserveModel.liquidityRate(), 21_177_019_511_735_318); //Liquidity rate: ~ 2.117%

        assertEq(reserveModel.totalSupply(), 16_431_999_999);
        assertEq(reserveModel.totalSupply(), reserveModel.currentTotalSupply());
    }

    function test_withdraw() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);

        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1e18);
        assertEq(state.liquidityIndex, 1e18);
        assertEq(state.accruedToTreasury, 0);
        assertEq(state.availableLiquidity, 2000e6);

        assertEq(reserveModel.totalDebt(), 8000e6);
        assertEq(reserveModel.utilization(), 0.8e18);

        assertEq(reserveModel.borrowRate(), 0.06e18);
        assertEq(reserveModel.liquidityRate(), 0.0432e18);

        assertEq(reserveModel.totalSupply(), 10_000e6);

        skip(365 days);

        assertLt(reserveModel.totalSupply(), reserveModel.currentTotalSupply());

        reserveModel.withdraw(1000e6);

        state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1.06e18);
        assertEq(state.liquidityIndex, 1.0432e18);
        assertEq(state.accruedToTreasury, 48e6);
        assertEq(state.availableLiquidity, 1000e6);

        assertEq(reserveModel.totalDebt(), 8_480_000_000);

        // 8480 / (8480 + 1000) ≈ 89.4515%
        assertEq(reserveModel.utilization(), 894_514_767_932_489_451);

        assertGt(reserveModel.borrowRate(), 0.06e18);
        assertGt(reserveModel.liquidityRate(), 0.0432e18);

        uint256 allAvailableLiquidity = state.availableLiquidity;

        reserveModel.withdraw(allAvailableLiquidity);

        state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1.06e18);
        assertEq(state.liquidityIndex, 1.0432e18);
        assertEq(state.accruedToTreasury, 48e6);
        assertEq(state.availableLiquidity, 0);

        assertEq(reserveModel.totalDebt(), 8_480_000_000);
        assertEq(reserveModel.utilization(), 1e18); //U == 100% !

        // When U = 100% =>
        // borrowRate =
        // BASE
        // + SLOPE1
        // + SLOPE2

        // =
        // 2% + 4% + 75%
        // =
        // 81%
        assertEq(reserveModel.borrowRate(), 810_000_000_000_000_000); //BorrowRate: ~ 81%
        assertEq(reserveModel.liquidityRate(), 729_000_000_000_000_000); //Liquidity rate: ~ 72.9%

        assertEq(reserveModel.totalSupply(), 8_431_999_998);
    }

    function test_withdraw_full_supply() public {
        reserveModel.setReserveState(0e6, 10_000e6, 10_000e6, 0.06e18, 0.0432e18, 0.1e18);

        // setup debt=0 / supply=10k / available=10k
        // → assert U=0
        // → assert borrowRate=BASE
        // → assert liquidityRate=0
        // → withdraw totalSupply
        // → totalScaledSupply=0
        // → totalSupply=0
        // → availableLiquidity=0

        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();

        assertEq(state.borrowIndex, 1e18);
        assertEq(state.liquidityIndex, 1e18);
        assertEq(state.accruedToTreasury, 0);
        assertEq(state.availableLiquidity, 10_000e6);

        assertEq(reserveModel.totalDebt(), 0e6);
        assertEq(reserveModel.utilization(), 0e18);

        assertEq(reserveModel.totalSupply(), 10_000e6);

        uint256 fullSupply = reserveModel.totalSupply();

        reserveModel.withdraw(fullSupply);

        state = reserveModel.getReserveState();

        assertEq(state.totalScaledSupply, 0);
        assertEq(reserveModel.totalSupply(), 0);
        assertEq(state.availableLiquidity, 0);
    }

    // adversarial tests

    function test_borrow_revertsWhenZeroAmount() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);

        vm.expectRevert(ReserveStateModel.ZeroAmount.selector);
        reserveModel.borrow(0e6);
    }

    function test_borrow_revertsWhenInsufficientLiquidity() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);

        vm.expectRevert(abi.encodeWithSelector(ReserveStateModel.InsufficientLiquidity.selector, 2001e6, 2000e6));
        reserveModel.borrow(2001e6);
    }

    function test_repay_revertsWhenZeroAmount() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);

        vm.expectRevert(ReserveStateModel.ZeroAmount.selector);
        reserveModel.repay(0e6);
    }

    function test_repay_revertsWhenCurrentDebtExceeded() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);

        vm.expectRevert(abi.encodeWithSelector(ReserveStateModel.CurrentDebtExceeded.selector, 8001e6, 8000e6));
        reserveModel.repay(8001e6);
    }

    function test_supply_revertsWhenZeroAmount() public {
        vm.expectRevert(ReserveStateModel.ZeroAmount.selector);
        reserveModel.supply(0e6);
    }

    function test_supply_revertsWhenSupplyTooSmall() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);
        skip(365 days);
        vm.expectRevert(abi.encodeWithSelector(ReserveStateModel.SupplyTooSmall.selector, 1));
        reserveModel.supply(1);
    }

    function test_withdraw_revertsWhenZeroAmount() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);
        vm.expectRevert(ReserveStateModel.ZeroAmount.selector);
        reserveModel.withdraw(0e6);
    }

    function test_withdraw_revertsWhenWithdrawExceedsSupply() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);
        vm.expectRevert(abi.encodeWithSelector(ReserveStateModel.WithdrawExceedsSupply.selector, 10_001e6, 10_000e6));
        reserveModel.withdraw(10_001e6);
    }

    function test_withdraw_revertsWhenInsufficientLiquidity() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);
        vm.expectRevert(abi.encodeWithSelector(ReserveStateModel.InsufficientLiquidity.selector, 2001e6, 2000e6));
        reserveModel.withdraw(2001e6);
    }

    function test_previewTimestamp_revertsWhenInvalidTimestamp() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);

        skip(365 days);

        reserveModel.supply(1000e6);

        ReserveStateModel.ReserveState memory state = reserveModel.getReserveState();

        uint256 timestamp = state.lastUpdateTimestamp - 1 days;

        vm.expectRevert(
            abi.encodeWithSelector(ReserveStateModel.InvalidTimestamp.selector, timestamp, state.lastUpdateTimestamp)
        );
        reserveModel.previewBorrowIndex(timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(ReserveStateModel.InvalidTimestamp.selector, timestamp, state.lastUpdateTimestamp)
        );
        reserveModel.previewLiquidityIndex(timestamp);
    }

    function test_repay_revertsWhenDebtReductionTooSmall() public {
        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);

        skip(365 days);
        reserveModel.accrueReserve();

        vm.expectRevert(abi.encodeWithSelector(ReserveStateModel.DebtReductionTooSmall.selector, 1));

        reserveModel.repay(1);
    }

    function testFuzz_indexesNeverDecrease(uint40 elapsed) public {
        elapsed = uint40(bound(elapsed, 0, 10 * 365 days));

        reserveModel.setReserveState(8000e6, 10_000e6, 2000e6, 0.06e18, 0.0432e18, 0.1e18);

        ReserveStateModel.ReserveState memory beforeState = reserveModel.getReserveState();

        skip(elapsed);
        reserveModel.accrueReserve();

        ReserveStateModel.ReserveState memory afterState = reserveModel.getReserveState();

        assertGe(afterState.borrowIndex, beforeState.borrowIndex);
        assertGe(afterState.liquidityIndex, beforeState.liquidityIndex);
    }
}
