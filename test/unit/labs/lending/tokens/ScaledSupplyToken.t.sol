// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { ScaledSupplyToken } from "src/labs/lending/tokens/ScaledSupplyToken.sol";
import { MockLiquidityIndexPool } from "test/mocks/MockLiquidityIndexPool.sol";

contract ScaledSupplyTokenTest is Test {
    ScaledSupplyToken token;
    MockLiquidityIndexPool pool;

    address alice = address(0x1001);
    address bob = address(0x1002);

    string name = "Scaled Supply USDC";
    string symbol = "sUSDC";
    uint8 decimals = 6;

    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event MintScaled(address indexed user, uint256 actualAmount, uint256 scaledAmount, uint256 index);
    event BurnScaled(address indexed user, uint256 actualAmount, uint256 scaledAmount, uint256 index);
    event BalanceTransfer(address indexed from, address indexed to, uint256 scaledAmount, uint256 index);

    function setUp() public {
        pool = new MockLiquidityIndexPool();
        token = new ScaledSupplyToken(address(pool), name, symbol, decimals);
    }

    function test_constructor_configuration() public {
        vm.expectRevert(ScaledSupplyToken.ZeroAddress.selector);
        new ScaledSupplyToken(address(0), name, symbol, decimals);

        assertEq(token.POOL(), address(pool));
        assertEq(token.name(), name);
        assertEq(token.symbol(), symbol);
        assertEq(token.decimals(), decimals);
    }

    function test_mintScaled_firstSupply() public {
        assertEq(token.scaledBalanceOf(alice), 0);
        assertEq(token.scaledTotalSupply(), 0);

        vm.prank(address(pool));
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, 1000e6);
        vm.expectEmit(true, false, false, true);
        emit MintScaled(alice, 1000e6, 1000e6, 1e18);
        bool firstSupply = token.mintScaled(alice, 1000e6);

        assertEq(token.scaledBalanceOf(alice), 1000e6);
        assertEq(token.scaledTotalSupply(), 1000e6);
        assertTrue(firstSupply);
    }

    function test_mintScaled_secondSupply() public {
        assertEq(token.scaledBalanceOf(alice), 0);
        assertEq(token.scaledTotalSupply(), 0);

        vm.prank(address(pool));
        bool firstSupply = token.mintScaled(alice, 1000e6);

        assertEq(token.scaledBalanceOf(alice), 1000e6);
        assertEq(token.scaledTotalSupply(), 1000e6);

        vm.prank(address(pool));
        bool isFirstSupply = token.mintScaled(alice, 500e6);

        assertEq(token.scaledBalanceOf(alice), 1500e6);
        assertEq(token.scaledTotalSupply(), 1500e6);
        assertFalse(isFirstSupply);
    }

    function test_mintScaled_multiUserMint() public {
        assertEq(token.scaledBalanceOf(alice), 0);
        assertEq(token.scaledTotalSupply(), 0);

        vm.prank(address(pool));
        bool firstSupply = token.mintScaled(alice, 1500e6);

        assertEq(token.scaledBalanceOf(alice), 1500e6);
        assertEq(token.scaledTotalSupply(), 1500e6);

        vm.prank(address(pool));
        bool isFirstSupply = token.mintScaled(bob, 500e6);

        assertEq(token.scaledBalanceOf(alice), 1500e6);
        assertEq(token.scaledBalanceOf(bob), 500e6);
        assertEq(token.scaledTotalSupply(), 2000e6);
    }

    function test_burnScaled_partial() public {
        test_mintScaled_multiUserMint();

        assertEq(token.scaledBalanceOf(alice), 1500e6);
        assertEq(token.scaledBalanceOf(bob), 500e6);
        assertEq(token.scaledTotalSupply(), 2000e6);

        vm.prank(address(pool));
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(0), 1000e6);
        vm.expectEmit(true, false, false, true);
        emit BurnScaled(alice, 1000e6, 1000e6, 1e18);
        bool zeroBalanceAfter = token.burnScaled(alice, 1000e6);

        assertFalse(zeroBalanceAfter);
        assertEq(token.scaledBalanceOf(alice), 500e6);
        assertEq(token.scaledBalanceOf(bob), 500e6);
        assertEq(token.scaledTotalSupply(), 1000e6);
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
        vm.expectRevert(ScaledSupplyToken.ZeroAddress.selector);
        token.mintScaled(address(0), 1000e6);

        vm.prank(address(pool));
        vm.expectRevert(ScaledSupplyToken.ZeroScaledAmount.selector);
        token.mintScaled(alice, 0e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyToken.OnlyPool.selector, alice));
        token.mintScaled(alice, 1000e6);
    }

    function test_burnScaled_reverts() public {
        vm.prank(address(pool));
        vm.expectRevert(ScaledSupplyToken.ZeroAddress.selector);
        token.burnScaled(address(0), 1000e6);

        vm.prank(address(pool));
        vm.expectRevert(ScaledSupplyToken.ZeroScaledAmount.selector);
        token.burnScaled(alice, 0e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyToken.OnlyPool.selector, alice));
        token.burnScaled(alice, 1000e6);

        vm.startPrank(address(pool));
        token.mintScaled(alice, 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyToken.ScaledBalanceExceeded.selector, alice, 1001e6, 1000e6));
        token.burnScaled(alice, 1001e6);
        vm.stopPrank();
    }

    function test_balanceOf_grows_through_index() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);

        assertEq(token.scaledBalanceOf(alice), 1000e6);
        assertEq(token.balanceOf(alice), 1000e6);

        pool.setLiquidityIndex(1.2e18);

        assertEq(token.scaledBalanceOf(alice), 1000e6);
        assertEq(token.balanceOf(alice), 1200e6);
    }

    function test_balanceOf_late_supplier() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);

        assertEq(token.scaledBalanceOf(alice), 1000e6);
        assertEq(token.balanceOf(alice), 1000e6);

        pool.setLiquidityIndex(1.0432e18);

        vm.prank(address(pool));
        token.mintScaled(bob, 479_294_478);

        assertEq(token.scaledBalanceOf(bob), 479_294_478);
        assertEq(token.balanceOf(bob), 499_999_999);

        assertEq(token.scaledBalanceOf(alice), 1000e6);
        assertEq(token.balanceOf(alice), 1_043_200_000);

        assertEq(token.scaledTotalSupply(), token.scaledBalanceOf(alice) + token.scaledBalanceOf(bob));

        uint256 summedBalances = token.balanceOf(alice) + token.balanceOf(bob);
        uint256 aggregateSupply = token.totalSupply();

        assertLe(summedBalances, aggregateSupply);
        assertLe(aggregateSupply - summedBalances, 1);
    }

    function test_transfer() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);

        assertEq(token.scaledBalanceOf(alice), 1000e6);
        assertEq(token.balanceOf(alice), 1000e6);

        assertEq(token.scaledTotalSupply(), token.scaledBalanceOf(alice));
        assertEq(token.totalSupply(), 1000e6);

        pool.setLiquidityIndex(1.0432e18);

        uint256 aliceScaledBefore = token.scaledBalanceOf(alice);
        uint256 bobScaledBefore = token.scaledBalanceOf(bob);
        uint256 totalSupplyBefore = token.totalSupply();
        uint256 scaledTotalSupplyBefore = token.scaledTotalSupply();

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 500e6);
        vm.expectEmit(true, true, false, true);
        emit BalanceTransfer(alice, bob, 479_294_479, 1.0432e18);
        token.transfer(bob, 500e6);

        assertEq(token.scaledBalanceOf(alice), 520_705_521);
        assertEq(token.balanceOf(alice), 543_199_999);

        assertEq(token.scaledBalanceOf(bob), 479_294_479);
        assertEq(token.balanceOf(bob), 500_000_000);

        assertEq(token.scaledTotalSupply(), aliceScaledBefore + bobScaledBefore);
        assertEq(token.scaledTotalSupply(), scaledTotalSupplyBefore);
        assertEq(token.totalSupply(), totalSupplyBefore);
    }

    function test_transfer_zeroAmount() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);

        assertEq(token.balanceOf(alice), 1000e6);
        assertEq(token.balanceOf(bob), 0e6);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 0e6);
        token.transfer(bob, 0e6);

        assertEq(token.balanceOf(alice), 1000e6);
        assertEq(token.balanceOf(bob), 0e6);
    }

    function test_transfer_selfTransfer() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);

        assertEq(token.balanceOf(alice), 1000e6);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, alice, 500e6);
        token.transfer(alice, 500e6);

        assertEq(token.balanceOf(alice), 1000e6);
    }

    function test_transfer_reverts() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyToken.InvalidRecipient.selector, address(0)));
        token.transfer(address(0), 500e6);

        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyToken.ScaledBalanceExceeded.selector, alice, 1001e6, 1000e6));
        token.transfer(bob, 1001e6);
        vm.stopPrank();
    }

    function test_approve() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);

        assertEq(token.balanceOf(alice), 1000e6);
        assertEq(token.allowance(alice, bob), 0);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Approval(alice, bob, 500e6);
        token.approve(bob, 500e6);

        assertEq(token.allowance(alice, bob), 500e6);
        assertEq(token.balanceOf(alice), 1000e6);
        assertEq(token.balanceOf(bob), 0e6);
    }

    function test_approve_revertsWhenSpenderIsZero() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);
        assertEq(token.balanceOf(alice), 1000e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyToken.InvalidSpender.selector, address(0)));
        token.approve(address(0), 500e6);
    }

    function test_transferFrom() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1500e6);

        assertEq(token.balanceOf(alice), 1500e6);
        assertEq(token.allowance(alice, bob), 0);

        vm.prank(alice);
        token.approve(bob, 1000e6);

        assertEq(token.allowance(alice, bob), 1000e6);

        vm.prank(bob);
        token.transferFrom(alice, bob, 500e6);

        assertEq(token.balanceOf(alice), 1000e6);
        assertEq(token.balanceOf(bob), 500e6);

        assertEq(token.allowance(alice, bob), 500e6);

        pool.setLiquidityIndex(1.0432e18);

        vm.prank(bob);
        token.transferFrom(alice, bob, 500e6);

        assertEq(token.balanceOf(alice), 543_199_999);
        assertEq(token.balanceOf(bob), 1_021_600_000);

        assertEq(token.allowance(alice, bob), 0e6);
    }

    function test_transferFrom_infinite_allowance() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1500e6);

        assertEq(token.balanceOf(alice), 1500e6);
        assertEq(token.allowance(alice, bob), 0);

        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        assertEq(token.allowance(alice, bob), type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, bob, 500e6);

        assertEq(token.balanceOf(alice), 1000e6);
        assertEq(token.balanceOf(bob), 500e6);

        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_transferFrom_revertsWhenInsufficientAllowance() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1500e6);

        assertEq(token.balanceOf(alice), 1500e6);
        assertEq(token.allowance(alice, bob), 0);

        vm.prank(alice);
        token.approve(bob, 1000e6);

        assertEq(token.allowance(alice, bob), 1000e6);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyToken.InsufficientAllowance.selector, bob, 1001e6, 1000e6));
        token.transferFrom(alice, bob, 1001e6);

        assertEq(token.allowance(alice, bob), 1000e6);
        assertEq(token.balanceOf(alice), 1500e6);
        assertEq(token.balanceOf(bob), 0e6);
    }

    function test_transferFrom_zeroAllowance() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1500e6);

        assertEq(token.balanceOf(alice), 1500e6);
        assertEq(token.allowance(alice, bob), 0);

        assertEq(token.allowance(alice, bob), 0e6);

        vm.prank(bob);
        token.transferFrom(alice, bob, 0e6);

        assertEq(token.balanceOf(alice), 1500e6);
        assertEq(token.balanceOf(bob), 0e6);

        assertEq(token.allowance(alice, bob), 0e6);
    }

    function test_transferFrom_selfTransfer() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1500e6);

        assertEq(token.balanceOf(alice), 1500e6);
        assertEq(token.allowance(alice, bob), 0);

        vm.prank(alice);
        token.approve(alice, 1000e6);

        assertEq(token.allowance(alice, alice), 1000e6);

        vm.prank(alice);
        token.transferFrom(alice, alice, 1000e6);

        assertEq(token.balanceOf(alice), 1500e6);

        assertEq(token.allowance(alice, alice), 0e6);
    }

    function test_transferFrom_revertsWhenBalanceExceeded_andPreservesAllowance() public {
        vm.prank(address(pool));
        token.mintScaled(alice, 1000e6);

        vm.prank(alice);
        token.approve(bob, 1500e6);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyToken.ScaledBalanceExceeded.selector, alice, 1500e6, 1000e6));
        token.transferFrom(alice, bob, 1500e6);

        assertEq(token.allowance(alice, bob), 1500e6);
        assertEq(token.scaledBalanceOf(alice), 1000e6);
        assertEq(token.scaledBalanceOf(bob), 0);
    }
}
