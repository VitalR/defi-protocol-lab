// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { ScaledDebtToken } from "src/labs/lending/tokens/ScaledDebtToken.sol";
import { MockBorrowIndexPool } from "test/mocks/MockBorrowIndexPool.sol";

contract ScaledDebtTokenTest is Test {
    ScaledDebtToken token;
    MockBorrowIndexPool pool;

    address alice = address(0x1001);
    address bob = address(0x1002);

    string name = "Variable Debt USDC";
    string symbol = "vdUSDC";
    uint8 decimals = 6;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event MintScaled(address indexed user, uint256 actualAmount, uint256 scaledAmount, uint256 index);
    event BurnScaled(address indexed user, uint256 actualAmount, uint256 scaledAmount, uint256 index);

    function setUp() public {
        pool = new MockBorrowIndexPool();
        token = new ScaledDebtToken(address(pool), name, symbol, decimals);
    }

    function test_constructor_configuration() public {
        vm.expectRevert(ScaledDebtToken.ZeroAddress.selector);
        new ScaledDebtToken(address(0), name, symbol, decimals);

        assertEq(token.POOL(), address(pool));
        assertEq(token.name(), name);
        assertEq(token.symbol(), symbol);
        assertEq(token.decimals(), decimals);
    }

    function test_mintScaled_firstBorrow() public {
        assertEq(token.scaledBalanceOf(alice), 0);
        assertEq(token.scaledTotalSupply(), 0);

        vm.prank(address(pool));
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, 1000e6);
        vm.expectEmit(true, false, false, true);
        emit MintScaled(alice, 1000e6, 1000e6, 1e18);
        bool firstBorrow = token.mintScaled(alice, 1000e6);

        assertEq(token.scaledBalanceOf(alice), 1000e6);
        assertEq(token.scaledTotalSupply(), 1000e6);
        assertTrue(firstBorrow);
    }

    function test_mintScaled_secondBorrow_atHigherIndex() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);

        pool.setBorrowIndex(1.06e18);

        assertEq(token.balanceOf(alice), 1060e6);

        vm.prank(address(pool));

        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), alice, 530e6);

        vm.expectEmit(true, false, false, true);
        emit MintScaled(alice, 530e6, 500e6, 1.06e18);

        bool firstBorrow = token.mintScaled(alice, 500e6);

        assertFalse(firstBorrow);
        assertEq(token.scaledBalanceOf(alice), 1500e6);
        assertEq(token.balanceOf(alice), 1590e6);
    }

    function test_mintScaled_multiUserMint() public {
        assertEq(token.scaledBalanceOf(alice), 0);
        assertEq(token.scaledTotalSupply(), 0);

        vm.prank(address(pool));
        bool firstBorrow = token.mintScaled(alice, 1000e6);
        assertTrue(firstBorrow);

        vm.prank(address(pool));
        bool isFirstAliceBorrow = token.mintScaled(alice, 500e6);
        assertFalse(isFirstAliceBorrow);
        assertEq(token.scaledBalanceOf(alice), 1500e6);
        assertEq(token.scaledTotalSupply(), 1500e6);

        vm.prank(address(pool));
        bool isFirstBobBorrow = token.mintScaled(bob, 500e6);
        assertTrue(isFirstBobBorrow);
        assertEq(token.scaledBalanceOf(alice), 1500e6);
        assertEq(token.scaledBalanceOf(bob), 500e6);
        assertEq(token.scaledTotalSupply(), 2000e6);
    }

    function test_burnScaled_partial_atHigherIndex() public {
        vm.startPrank(address(pool));
        token.mintScaled(alice, 1500e6);
        vm.stopPrank();

        pool.setBorrowIndex(1.06e18);

        assertEq(token.balanceOf(alice), 1590e6);

        vm.prank(address(pool));

        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, address(0), 1060e6);

        vm.expectEmit(true, false, false, true);
        emit BurnScaled(alice, 1060e6, 1000e6, 1.06e18);

        bool zeroBalanceAfter = token.burnScaled(alice, 1000e6);

        // before = ceil(1500 × 1.06) = 1590
        // after  = ceil(500 × 1.06)  = 530
        // burned = 1060
        assertFalse(zeroBalanceAfter);
        assertEq(token.scaledBalanceOf(alice), 500e6);
        assertEq(token.balanceOf(alice), 530e6);
    }

    function test_burnScaled_full() public {
        test_mintScaled_multiUserMint();

        assertEq(token.scaledBalanceOf(alice), 1500e6);
        assertEq(token.scaledBalanceOf(bob), 500e6);
        assertEq(token.scaledTotalSupply(), 2000e6);

        vm.prank(address(pool));
        bool zeroBalanceAfter = token.burnScaled(alice, 1500e6);

        assertTrue(zeroBalanceAfter);
        assertEq(token.scaledBalanceOf(alice), 0e6);
        assertEq(token.scaledBalanceOf(bob), 500e6);
        assertEq(token.scaledTotalSupply(), 500e6);
    }

    function test_mintScaled_reverts() public {
        vm.prank(address(pool));
        vm.expectRevert(ScaledDebtToken.ZeroAddress.selector);
        token.mintScaled(address(0), 1000e6);

        vm.prank(address(pool));
        vm.expectRevert(ScaledDebtToken.ZeroScaledAmount.selector);
        token.mintScaled(alice, 0e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ScaledDebtToken.OnlyPool.selector, alice));
        token.mintScaled(alice, 1000e6);
    }

    function test_burnScaled_reverts() public {
        vm.prank(address(pool));
        vm.expectRevert(ScaledDebtToken.ZeroAddress.selector);
        token.burnScaled(address(0), 1000e6);

        vm.prank(address(pool));
        vm.expectRevert(ScaledDebtToken.ZeroScaledAmount.selector);
        token.burnScaled(alice, 0e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ScaledDebtToken.OnlyPool.selector, alice));
        token.burnScaled(alice, 1000e6);

        vm.startPrank(address(pool));
        token.mintScaled(alice, 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ScaledDebtToken.ScaledDebtExceeded.selector, alice, 1001e6, 1000e6));
        token.burnScaled(alice, 1001e6);
        vm.stopPrank();
    }

    function test_balanceOf_grows_through_index() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);

        assertEq(token.scaledBalanceOf(alice), 1000e6);
        assertEq(token.balanceOf(alice), 1000e6);

        pool.setBorrowIndex(1.2e18);

        assertEq(token.scaledBalanceOf(alice), 1000e6);
        assertEq(token.balanceOf(alice), 1200e6);
    }

    function test_balanceOf_lateBorrower() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);

        assertEq(token.scaledBalanceOf(alice), 1000e6);
        assertEq(token.balanceOf(alice), 1000e6);

        pool.setBorrowIndex(1.06e18);

        vm.prank(address(pool));
        token.mintScaled(bob, 471_698_114);

        // scaled = ceil(500e6 / 1.06)
        //        = 471,698,114
        assertEq(token.scaledBalanceOf(bob), 471_698_114);

        // actual debt = ceil(471,698,114 × 1.06)
        //             = 500,000,001
        assertEq(token.balanceOf(bob), 500_000_001);

        assertEq(token.scaledBalanceOf(alice), 1000e6);
        assertEq(token.balanceOf(alice), 1_060_000_000);

        assertEq(token.scaledTotalSupply(), token.scaledBalanceOf(alice) + token.scaledBalanceOf(bob));

        uint256 summedDebt = token.balanceOf(alice) + token.balanceOf(bob);
        uint256 aggregateDebt = token.totalSupply();

        // Σ user debt >= aggregate debt
        assertGe(summedDebt, aggregateDebt);
        // summedDebt - aggregateDebt <= N - 1
        assertLe(summedDebt - aggregateDebt, 1);
    }

    function test_transfer() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);
        assertEq(token.balanceOf(alice), 1000e6);

        vm.expectRevert(ScaledDebtToken.OperationNotSupported.selector);
        token.transfer(alice, 1000e6);
        assertEq(token.balanceOf(alice), 1000e6);
    }

    function test_transferFrom() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);
        assertEq(token.balanceOf(alice), 1000e6);

        vm.expectRevert(ScaledDebtToken.OperationNotSupported.selector);
        token.transferFrom(alice, bob, 1000e6);
        assertEq(token.balanceOf(alice), 1000e6);
    }

    function test_approve() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);

        vm.prank(alice);
        vm.expectRevert(ScaledDebtToken.OperationNotSupported.selector);
        token.approve(bob, 500e6);
    }

    function test_allowance() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);

        vm.prank(alice);
        vm.expectRevert(ScaledDebtToken.OperationNotSupported.selector);
        token.allowance(alice, bob);
    }

    function test_totalSupply_roundingGap() public {
        pool.setBorrowIndex(1.5e18);

        vm.startPrank(address(pool));
        token.mintScaled(alice, 1);
        token.mintScaled(bob, 1);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 2);
        assertEq(token.balanceOf(bob), 2);

        assertEq(token.totalSupply(), 3);

        uint256 summedDebt = token.balanceOf(alice) + token.balanceOf(bob);

        // ceil(A) + ceil(B) = ceil(A + B)
        // Alice: ceil(1 × 1.5) = 2
        // Bob:   ceil(1 × 1.5) = 2
        // Total: ceil(2 × 1.5) = 3
        assertEq(summedDebt - token.totalSupply(), 1);
    }

    function test_balanceOf_revertsWhenBorrowIndexBelowWad() public {
        pool.setBorrowIndex(0.99e18);

        vm.expectRevert(abi.encodeWithSelector(ScaledDebtToken.InvalidBorrowIndex.selector, 0.99e18));
        token.balanceOf(alice);
    }
}
