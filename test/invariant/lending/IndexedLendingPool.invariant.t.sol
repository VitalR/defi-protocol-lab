// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { IndexedLendingPool, DecimalMath, Math } from "src/labs/lending/IndexedLendingPool.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";

contract IndexedLendingPoolHandler is Test {
    IndexedLendingPool public immutable pool;
    MockUSDC public immutable usdc;

    uint256 public lastBorrowIndex;
    uint256 public lastLiquidityIndex;

    bool public borrowIndexDecreased;
    bool public liquidityIndexDecreased;

    address[3] public actors = [address(0x1001), address(0x1002), address(0x1003)];

    constructor(IndexedLendingPool pool_, MockUSDC usdc_) {
        pool = pool_;
        usdc = usdc_;

        lastBorrowIndex = pool_.currentBorrowIndex();
        lastLiquidityIndex = pool_.currentLiquidityIndex();
    }

    function supply(uint256 actorSeed, uint256 rawAmount) external {
        address actor = actors[actorSeed % actors.length];

        uint256 index = pool.currentLiquidityIndex();

        uint256 minimumAmount = Math.mulDiv(index, 1, DecimalMath.WAD, Math.Rounding.Ceil);

        uint256 maximumAmount = 1_000_000e6;

        if (minimumAmount > maximumAmount) return;

        // floor(amount × WAD / liquidityIndex) >= 1
        uint256 amount = bound(rawAmount, minimumAmount, maximumAmount);

        usdc.mint(actor, amount);

        vm.startPrank(actor);
        usdc.approve(address(pool), amount);
        pool.supply(amount, actor);
        vm.stopPrank();

        _observeIndexes();
    }

    function borrow(uint256 actorSeed, uint256 rawAmount) external {
        uint256 liquidity = pool.availableLiquidity();
        if (liquidity == 0) return;

        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(rawAmount, 1, liquidity);

        vm.prank(actor);
        pool.borrow(amount, actor);

        _observeIndexes();
    }

    function repay(uint256 actorSeed, uint256 rawAmount) external {
        address actor = actors[actorSeed % actors.length];

        uint256 debt = pool.DEBT_TOKEN().balanceOf(actor);

        if (debt == 0) return;

        uint256 index = pool.currentBorrowIndex();

        uint256 minimumPartialRepay = Math.mulDiv(index, 1, DecimalMath.WAD, Math.Rounding.Ceil);

        uint256 amount;

        // Approximately 25% of generated calls exercise full repayment.
        bool fullRepay = rawAmount % 4 == 0;

        if (fullRepay || debt <= minimumPartialRepay) {
            amount = debt;
        } else {
            amount = bound(rawAmount, minimumPartialRepay, debt - 1);
        }

        uint256 balance = usdc.balanceOf(actor);

        if (balance < amount) {
            usdc.mint(actor, amount - balance);
        }

        vm.startPrank(actor);
        usdc.approve(address(pool), amount);
        pool.repay(amount, actor);
        vm.stopPrank();

        _observeIndexes();
    }

    function withdraw(uint256 actorSeed, uint256 rawAmount) external {
        address actor = actors[actorSeed % actors.length];

        uint256 claim = pool.SUPPLY_TOKEN().balanceOf(actor);
        uint256 liquidity = pool.availableLiquidity();
        uint256 maximum = Math.min(claim, liquidity);

        if (maximum == 0) return;

        uint256 amount = bound(rawAmount, 1, maximum);

        vm.prank(actor);
        pool.withdraw(amount, actor);

        _observeIndexes();
    }

    function warp(uint256 rawElapsed) external {
        uint256 elapsed = bound(rawElapsed, 1, 30 days);
        skip(elapsed);

        _observeIndexes();
    }

    function donate(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 1, 1000e6);

        usdc.mint(address(this), amount);
        usdc.transfer(address(pool), amount);
    }

    function _observeIndexes() internal {
        uint256 borrowIndex = pool.currentBorrowIndex();
        uint256 liquidityIndex = pool.currentLiquidityIndex();

        if (borrowIndex < lastBorrowIndex) {
            borrowIndexDecreased = true;
        }

        if (liquidityIndex < lastLiquidityIndex) {
            liquidityIndexDecreased = true;
        }

        lastBorrowIndex = borrowIndex;
        lastLiquidityIndex = liquidityIndex;
    }
}

contract IndexedLendingPoolInvariantTest is Test {
    IndexedLendingPool pool;
    IndexedLendingPoolHandler handler;
    MockUSDC usdc;

    function setUp() public {
        usdc = new MockUSDC();
        pool = new IndexedLendingPool(address(usdc));
        handler = new IndexedLendingPoolHandler(pool, usdc);

        targetContract(address(handler));
    }

    function invariant_cashReconciliation() public view {
        assertEq(usdc.balanceOf(address(pool)), pool.availableLiquidity() + pool.unaccountedCash());
    }

    function invariant_indexesNeverDecrease() public view {
        assertFalse(handler.borrowIndexDecreased());
        assertFalse(handler.liquidityIndexDecreased());
    }

    function invariant_indexesAreBoundedAndPreviewNotBelowStored() public view {
        IndexedLendingPool.ReserveState memory state = pool.getReserveState();

        assertGe(state.borrowIndex, DecimalMath.WAD);
        assertGe(state.liquidityIndex, DecimalMath.WAD);

        assertGe(pool.currentBorrowIndex(), state.borrowIndex);
        assertGe(pool.currentLiquidityIndex(), state.liquidityIndex);
    }

    function invariant_utilizationAndRatesAreBounded() public view {
        assertLe(pool.utilization(), DecimalMath.WAD);

        assertGe(pool.borrowRate(), pool.BASE_RATE());

        assertLe(pool.borrowRate(), pool.BASE_RATE() + pool.SLOPE1() + pool.SLOPE2());

        assertLe(pool.liquidityRate(), pool.borrowRate());
    }

    function invariant_protocolIsNotAccountingInsolvent() public view {
        IndexedLendingPool.ReserveState memory state = pool.getReserveState();

        uint256 assets = pool.availableLiquidity() + pool.totalDebt();

        uint256 liabilities = pool.totalSupply() + state.accruedToTreasury;

        // Conservative rounding must benefit the reserve.
        assertGe(assets, liabilities);
    }

    function invariant_scaledTotalsEqualKnownUserPositions() public view {
        uint256 supplySum;
        uint256 debtSum;

        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);

            supplySum += pool.SUPPLY_TOKEN().scaledBalanceOf(actor);
            debtSum += pool.DEBT_TOKEN().scaledBalanceOf(actor);
        }

        assertEq(supplySum, pool.totalScaledSupply());
        assertEq(debtSum, pool.totalScaledDebt());
    }
}

// forge test --match-path test/invariant/lending/IndexedLendingPool.invariant.t.sol
