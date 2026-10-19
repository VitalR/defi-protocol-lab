// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";

import { VulnerableVault } from "src/security/reentrancy/single-function/VulnerableVault.sol";
import { SafeVault } from "src/security/reentrancy/single-function/SafeVault.sol";
import { ReentrantAttacker } from "src/security/reentrancy/single-function/ReentrantAttacker.sol";

import { CrossFunctionVault } from "src/security/reentrancy/cross-function/CrossFunctionVault.sol";
import { CrossFunctionAttacker } from "src/security/reentrancy/cross-function/CrossFunctionAttacker.sol";

import {
    VulnerableReadOnlyPool,
    SafeReadOnlyPool,
    SafeReentrancyGuardReadOnlyPool
} from "src/security/reentrancy/read-only/VulnerableReadOnlyPool.sol";
import { DependentProtocol } from "src/security/reentrancy/read-only/DependentProtocol.sol";
import { ReadOnlyAttacker } from "src/security/reentrancy/read-only/ReadOnlyAttacker.sol";

contract ReentrancyTest is Test {
    VulnerableVault vulnerableVault;
    SafeVault safeVault;
    ReentrantAttacker reentrantAttacker;
    VulnerableReadOnlyPool pool;
    DependentProtocol dependent;

    address alice;
    address bob;
    address attacker;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        attacker = makeAddr("attacker");

        vulnerableVault = new VulnerableVault();
        reentrantAttacker = new ReentrantAttacker(vulnerableVault, attacker);

        pool = new VulnerableReadOnlyPool();
        dependent = new DependentProtocol(address(pool));

        vm.deal(alice, 5 ether);
    }

    function test_normalWithdrawal() public {
        assertEq(alice.balance, 5 ether);
        assertEq(address(vulnerableVault).balance, 0);

        vm.prank(alice);
        vulnerableVault.deposit{ value: 5 ether }();

        assertEq(alice.balance, 0);
        assertEq(address(vulnerableVault).balance, 5 ether);

        vm.prank(alice);
        vulnerableVault.withdraw();

        assertEq(alice.balance, 5 ether);
        assertEq(address(vulnerableVault).balance, 0);
    }

    function test_singleFunctionReentrancyDrainsVault() public {
        assertEq(alice.balance, 5 ether);
        assertEq(address(vulnerableVault).balance, 0);

        vm.deal(attacker, 1 ether);
        assertEq(attacker.balance, 1 ether);
        assertEq(address(reentrantAttacker).balance, 0);

        vm.prank(alice);
        vulnerableVault.deposit{ value: 5 ether }();

        assertEq(alice.balance, 0);
        assertEq(address(vulnerableVault).balance, 5 ether);
        assertEq(attacker.balance, 1 ether);
        assertEq(address(reentrantAttacker).balance, 0);

        vm.startPrank(attacker);
        reentrantAttacker.attack{ value: 1 ether }();

        assertEq(alice.balance, 0);
        assertEq(address(vulnerableVault).balance, 0);
        assertEq(attacker.balance, 0);
        assertEq(address(reentrantAttacker).balance, 6 ether);
    }

    function test_ceiBlocksSingleFunctionReentrancy() public {
        safeVault = new SafeVault();

        assertEq(alice.balance, 5 ether);
        assertEq(address(safeVault).balance, 0);

        vm.deal(attacker, 1 ether);
        assertEq(attacker.balance, 1 ether);
        assertEq(address(reentrantAttacker).balance, 0);

        vm.prank(alice);
        safeVault.deposit{ value: 5 ether }();

        assertEq(alice.balance, 0);
        assertEq(address(safeVault).balance, 5 ether);
        assertEq(attacker.balance, 1 ether);
        assertEq(address(reentrantAttacker).balance, 0);

        vm.startPrank(attacker);
        reentrantAttacker.updateVault(address(safeVault));
        vm.expectRevert();
        reentrantAttacker.attack{ value: 1 ether }();
        vm.stopPrank();

        assertEq(alice.balance, 0);
        assertEq(address(safeVault).balance, 5 ether);
        assertEq(attacker.balance, 1 ether);
        assertEq(address(reentrantAttacker).balance, 0);
    }

    function test_crossFunctionReentrancyCreatesSecondClaim() public {
        CrossFunctionVault crossFunctionVault = new CrossFunctionVault();
        CrossFunctionAttacker crossFunctionAttacker = new CrossFunctionAttacker(crossFunctionVault, attacker, bob);

        vm.deal(attacker, 1 ether);

        assertEq(attacker.balance, 1 ether);
        assertEq(address(crossFunctionVault).balance, 0 ether);

        assertEq(bob.balance, 0 ether);
        assertEq(crossFunctionVault.balances(bob), 0 ether);

        vm.startPrank(attacker);

        crossFunctionAttacker.attack{ value: 1 ether }();

        vm.stopPrank();

        assertEq(attacker.balance, 0 ether);
        assertEq(address(crossFunctionAttacker).balance, 1 ether);

        assertEq(address(crossFunctionVault).balance, 0 ether);

        assertEq(crossFunctionVault.balances(attacker), 0 ether);

        assertEq(bob.balance, 0 ether);
        assertEq(crossFunctionVault.balances(bob), 1 ether);

        // So the final state is:

        // attacker has physically received 1 ETH

        // AND

        // bob still has an internal claim for 1 ETH

        // You've duplicated economic value.
    }

    function test_ceiBlocksCrossFunctionReentrancy() public {
        CrossFunctionVault crossFunctionVault = new CrossFunctionVault();
        CrossFunctionAttacker crossFunctionAttacker = new CrossFunctionAttacker(crossFunctionVault, attacker, bob);

        vm.deal(attacker, 1 ether);

        assertEq(attacker.balance, 1 ether);

        assertEq(address(crossFunctionVault).balance, 0 ether);

        assertEq(bob.balance, 0 ether);

        vm.startPrank(attacker);

        vm.expectRevert();
        crossFunctionAttacker.safeAttack{ value: 1 ether }();

        vm.stopPrank();

        assertEq(attacker.balance, 1 ether);
        assertEq(address(crossFunctionAttacker).balance, 0 ether);

        assertEq(address(crossFunctionVault).balance, 0 ether);

        assertEq(crossFunctionVault.balances(attacker), 0 ether);

        assertEq(bob.balance, 0 ether);
        assertEq(crossFunctionVault.balances(bob), 0 ether);
    }

    function test_normalPriceIsCorrect() public {
        vm.deal(alice, 10 ether);

        vm.prank(alice);
        pool.deposit{ value: 10 ether }();

        assertEq(address(pool).balance, 10 ether);
        assertEq(pool.totalShares(), 10 ether);

        assertEq(pool.pricePerShare(), 1 ether);
    }

    function test_readOnlyReentrancyObservesIntermediateState() public {
        vm.deal(alice, 5 ether);

        vm.prank(alice);
        pool.deposit{ value: 5 ether }();

        ReadOnlyAttacker attackerContract = new ReadOnlyAttacker(address(pool), address(dependent));

        vm.deal(attacker, 5 ether);

        vm.prank(attacker);
        attackerContract.deposit{ value: 5 ether }();

        assertEq(pool.pricePerShare(), 1 ether);

        vm.prank(attacker);
        attackerContract.attack(5 ether);

        // Final pool state is perfectly normal.
        assertEq(pool.pricePerShare(), 1 ether);

        // But dependent protocol observed the temporary state.
        assertEq(dependent.lastPrice(), 0.5 ether);
    }

    function test_consistentStateBeforeInteractionPreventsBadQuote() public {
        SafeReadOnlyPool safePool = new SafeReadOnlyPool();

        ReadOnlyAttacker attackerContract = new ReadOnlyAttacker(address(safePool), address(dependent));

        vm.deal(alice, 5 ether);

        vm.prank(alice);
        safePool.deposit{ value: 5 ether }();

        vm.deal(attacker, 5 ether);

        vm.prank(attacker);
        attackerContract.deposit{ value: 5 ether }();

        assertEq(safePool.pricePerShare(), 1 ether);

        vm.prank(attacker);

        attackerContract.attack(5 ether);

        assertEq(safePool.pricePerShare(), 1 ether);

        assertEq(dependent.lastPrice(), 1 ether);
    }

    function test_nonReentrantViewBlocksReadDuringGuardedExecution() public {
        SafeReentrancyGuardReadOnlyPool guardedPool = new SafeReentrancyGuardReadOnlyPool();

        DependentProtocol guardedDependent = new DependentProtocol(address(guardedPool));

        ReadOnlyAttacker attackerContract = new ReadOnlyAttacker(address(guardedPool), address(guardedDependent));

        vm.deal(alice, 5 ether);

        vm.prank(alice);
        guardedPool.deposit{ value: 5 ether }();

        vm.deal(attacker, 5 ether);

        vm.prank(attacker);
        attackerContract.deposit{ value: 5 ether }();

        assertEq(guardedPool.pricePerShare(), 1 ether);

        vm.prank(attacker);

        vm.expectRevert(); //SafeReentrancyGuardReadOnlyPool.ReentrantCall.selector

        // withdraw()
        //     ↓
        // lock = true
        //     ↓
        // send ETH to attacker
        //     ↓
        // receive()
        //     ↓
        // snapshotPrice()
        //     ↓
        // pricePerShare()
        //     ↓
        // ReentrantCall()

        attackerContract.attack(5 ether);

        // read-only guard rejects read
        //     ↓
        // attacker callback reverts
        //         ↓
        // ETH call fails
        //         ↓
        // withdraw reverts
        //         ↓
        // whole transaction rolls back
    }
}
