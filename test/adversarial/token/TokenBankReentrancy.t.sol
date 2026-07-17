// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { TokenBank, ReentrancyGuard } from "src/labs/token/TokenBank.sol";
import { TokenBankAttacker } from "test/helpers/TokenBankAttacker.sol";
import { MockCallbackERC20, ERC20Reentrant } from "test/mocks/MockCallbackERC20.sol";

contract TokenBankReentrancyTest is Test {
    TokenBank bank;
    MockCallbackERC20 token;

    address user = address(0x1001);
    address attacker = address(0x1002);
    uint256 amount = 1000 ether;

    function setUp() public {
        bank = new TokenBank();
        token = new MockCallbackERC20();

        token.mint(attacker, amount);
    }

    function test_Deposit_CreditsReceivedAmount() public {
        assertEq(bank.balanceOf(attacker, address(token)), 0);

        vm.startPrank(attacker);
        token.approve(address(bank), amount);
        bank.deposit(address(token), amount);
        vm.stopPrank();

        assertEq(bank.balanceOf(attacker, address(token)), amount);
    }

    function test_WithdrawVulnerable_RevertsWhenAmountExceedsBalance() public {
        TokenBankAttacker attackerContract = new TokenBankAttacker(bank, token);

        // Honest user supplies additional bank liquidity.
        token.mint(user, amount);

        vm.startPrank(user);
        token.approve(address(bank), amount);
        bank.deposit(address(token), amount);
        vm.stopPrank();

        // Attacker deposits the same amount.
        token.mint(address(attackerContract), amount);
        attackerContract.deposit(amount);

        assertEq(token.balanceOf(address(bank)), amount * 2);
        assertEq(bank.balanceOf(address(attackerContract), address(token)), amount);

        token.scheduleReenter(
            ERC20Reentrant.Type.After,
            address(attackerContract),
            abi.encodeCall(TokenBankAttacker.reenterVulnerable, ())
        );

        vm.expectRevert(abi.encodeWithSelector(TokenBank.InsufficientBalance.selector, amount, amount * 2));
        attackerContract.attackVulnerable(amount * 2);

        assertEq(bank.balanceOf(user, address(token)), amount);
        assertEq(bank.balanceOf(address(attackerContract), address(token)), amount);
    }

    function test_WithdrawVulnerable_DrainsOtherDepositor() public {
        TokenBankAttacker attackerContract = new TokenBankAttacker(bank, token);

        // Honest user supplies additional bank liquidity.
        token.mint(user, amount);

        vm.startPrank(user);
        token.approve(address(bank), amount);
        bank.deposit(address(token), amount);
        vm.stopPrank();

        assertEq(token.balanceOf(address(bank)), amount);
        assertEq(bank.balanceOf(user, address(token)), amount);

        // Attacker deposits the same amount.
        token.mint(address(attackerContract), amount);
        attackerContract.deposit(amount);

        assertEq(token.balanceOf(address(bank)), amount * 2);
        assertEq(bank.balanceOf(address(attackerContract), address(token)), amount);

        token.scheduleReenter(
            ERC20Reentrant.Type.After,
            address(attackerContract),
            abi.encodeCall(TokenBankAttacker.reenterVulnerable, ())
        );

        attackerContract.attackVulnerable(amount);

        // Attacker withdrew twice against one deposit.
        assertEq(token.balanceOf(address(attackerContract)), amount * 2);
        assertEq(bank.balanceOf(address(attackerContract), address(token)), 0);

        // Honest user's claim remains, but the bank is insolvent.
        assertEq(bank.balanceOf(user, address(token)), amount);
        assertEq(token.balanceOf(address(bank)), 0);

        // After exploitation:
        // Bank token assets:          0
        // Attacker internal balance:  0
        // Honest-user liability:      1000 tokens
        // Attacker wallet balance:    2000 tokens
    }

    function test_WithdrawProtected_BlocksReentrancy() public {
        TokenBankAttacker attackerContract = new TokenBankAttacker(bank, token);

        // Honest user supplies additional bank liquidity.
        token.mint(user, amount);

        vm.startPrank(user);
        token.approve(address(bank), amount);
        bank.deposit(address(token), amount);
        vm.stopPrank();

        // Attacker deposits the same amount.
        token.mint(address(attackerContract), amount);
        attackerContract.deposit(amount);

        assertEq(token.balanceOf(address(bank)), amount * 2);
        assertEq(bank.balanceOf(address(attackerContract), address(token)), amount);

        token.scheduleReenter(
            ERC20Reentrant.Type.After, address(attackerContract), abi.encodeCall(TokenBankAttacker.reenterProtected, ())
        );
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attackerContract.attackProtected(amount);

        assertEq(token.balanceOf(address(attackerContract)), 0);
        assertEq(bank.balanceOf(address(attackerContract), address(token)), amount);

        assertEq(bank.balanceOf(user, address(token)), amount);
        assertEq(token.balanceOf(address(bank)), amount * 2);
    }
}
