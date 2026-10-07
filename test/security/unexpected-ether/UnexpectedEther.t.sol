// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { VulnerableGame } from "src/security/unexpected-ether/VulnerableGame.sol";
import { ForceEther } from "src/security/unexpected-ether/ForceEther.sol";
import { SafeGame } from "src/security/unexpected-ether/SafeGame.sol";

// 1. A contract cannot guarantee that nobody sends it ETH.

// 2. receive()/fallback() only control normal message-call transfers.

// 3. Do not use address(this).balance as authoritative
//    business/accounting state unless unsolicited ETH is explicitly handled.

contract UnexpectedEtherTest is Test {
    VulnerableGame vulnerableGame;
    ForceEther forceEther;
    SafeGame safeGame;

    address alice;
    address bob;
    address attacker;

    function setUp() public {
        alice = makeAddr("alice");
        attacker = makeAddr("attacker");

        vulnerableGame = new VulnerableGame();
    }

    function test_targetReachedNormally() public {
        // 10 legitimate users/deposits
        vm.deal(alice, 10 ether);

        for (uint256 i; i < 10; ++i) {
            vm.prank(alice);
            vulnerableGame.deposit{ value: 1 ether }();
        }

        assertEq(address(vulnerableGame).balance, 10 ether);
        assertTrue(vulnerableGame.targetReached());
    }

    function test_directEtherTransferRejected() public {
        vm.deal(bob, 1 ether);

        vm.prank(bob);
        (bool success,) = address(vulnerableGame).call{ value: 1 ether }("");

        assertFalse(success);
    }

    function test_forceEtherBypassesReceive() public {
        assertEq(address(vulnerableGame).balance, 0 ether);

        ForceEther forceEther = new ForceEther{ value: 0.5 ether }();

        vm.prank(attacker);
        forceEther.force(payable(address(vulnerableGame)));

        assertEq(address(vulnerableGame).balance, 0.5 ether);
    }

    // Build the actual DoS

    // Step 1
    // 9 legitimate deposits
    // balance = 9 ETH

    // Step 2
    // attacker force-sends 0.5 ETH
    // balance = 9.5 ETH

    // Step 3
    // legitimate user deposits 1 ETH
    // tentative balance = 10.5 ETH

    // Step 4
    // contract sees balance > 10 ETH
    // reverts

    // Step 5
    // state is stuck:
    // balance = 9.5 ETH

    // griefing/DoS attack caused by a dangerous balance invariant
    function test_forcedEtherBreaksTargetInvariant() public {
        // deposit 9 ETH legitimately
        vm.deal(alice, 10 ether);

        for (uint256 i; i < 9; ++i) {
            vm.prank(alice);
            vulnerableGame.deposit{ value: 1 ether }();
        }

        assertEq(address(vulnerableGame).balance, 9 ether);
        assertFalse(vulnerableGame.targetReached());

        // deploy ForceEther with 0.5 ETH
        ForceEther forceEther = new ForceEther{ value: 0.5 ether }();

        // force-send to VulnerableGame
        vm.prank(attacker);
        forceEther.force(payable(address(vulnerableGame)));

        assertEq(address(vulnerableGame).balance, 9.5 ether);

        vm.prank(alice);
        vm.expectRevert(VulnerableGame.TargetReached.selector);

        vulnerableGame.deposit{ value: 1 ether }();

        assertFalse(vulnerableGame.targetReached());
    }

    // VULNERABLE

    // protocol accounting
    //     =
    // address(this).balance

    // SAFE

    // protocol accounting
    //     =
    // explicit internal state
    function test_internalAccountingIgnoresForcedEther() public {
        safeGame = new SafeGame();

        vm.deal(alice, 10 ether);

        for (uint256 i; i < 9; ++i) {
            vm.prank(alice);
            safeGame.deposit{ value: 1 ether }();
        }

        assertEq(address(safeGame).balance, 9 ether);
        assertFalse(safeGame.targetReached());
        assertEq(safeGame.accountedDeposits(), 9 ether);

        ForceEther forceEther = new ForceEther{ value: 0.5 ether }();

        vm.prank(attacker);
        forceEther.force(payable(address(safeGame)));

        assertEq(address(safeGame).balance, 9.5 ether);
        assertEq(safeGame.accountedDeposits(), 9 ether);

        vm.prank(alice);
        safeGame.deposit{ value: 1 ether }();

        assertEq(address(safeGame).balance, 10.5 ether);
        assertEq(safeGame.accountedDeposits(), 10 ether);
        assertTrue(safeGame.targetReached());
    }
}
