// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { IndexedLendingPool } from "src/labs/lending/IndexedLendingPool.sol";
import { ScaledSupplyToken } from "src/labs/lending/tokens/ScaledSupplyToken.sol";
import { ScaledDebtToken } from "src/labs/lending/tokens/ScaledDebtToken.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";

contract IndexedLendingPoolTest is Test {
    IndexedLendingPool pool;
    MockUSDC usdc;

    function setUp() public {
        usdc = new MockUSDC();
        pool = new IndexedLendingPool(address(usdc));
    }

    function test_constructor_configuration() public {
        assertEq(address(pool.UNDERLYING()), address(usdc));

        assertEq(pool.currentLiquidityIndex(), 1e18);
        assertEq(pool.currentBorrowIndex(), 1e18);

        ScaledSupplyToken supplyToken = pool.SUPPLY_TOKEN();
        ScaledDebtToken debtToken = pool.DEBT_TOKEN();

        assertEq(supplyToken.POOL(), address(pool));
        assertEq(debtToken.POOL(), address(pool));

        assertEq(supplyToken.decimals(), 6);
        assertEq(debtToken.decimals(), 6);

        assertEq(supplyToken.symbol(), "aUSDC");
        assertEq(debtToken.symbol(), "vdUSDC");
    }

    function test_constructor_revertsWhenUnderlyingIsZero() public {
        vm.expectRevert(IndexedLendingPool.ZeroAddress.selector);
        new IndexedLendingPool(address(0));
    }

    function test_constructor_revertsWhenInvalidUnderlying() public {
        address nonContract = address(0xBEEF);

        assertEq(nonContract.code.length, 0);

        vm.expectRevert(abi.encodeWithSelector(IndexedLendingPool.InvalidUnderlying.selector, nonContract));
        new IndexedLendingPool(nonContract);
    }

    function test_positionTokenNames() public {
        assertEq(pool.SUPPLY_TOKEN().name(), "Indexed Supply USDC");

        assertEq(pool.DEBT_TOKEN().name(), "Variable Debt USDC");
    }

    function test_positionTokens_rejectDirectMint() public {
        ScaledSupplyToken supplyToken = pool.SUPPLY_TOKEN();

        ScaledDebtToken debtToken = pool.DEBT_TOKEN();

        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyToken.OnlyPool.selector, address(this)));
        supplyToken.mintScaled(address(this), 1000e6);

        vm.expectRevert(abi.encodeWithSelector(ScaledDebtToken.OnlyPool.selector, address(this)));
        debtToken.mintScaled(address(this), 1000e6);
    }
}
