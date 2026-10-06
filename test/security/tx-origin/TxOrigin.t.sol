// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { VulnerableVault } from "src/security/tx-origin/VulnerableVault.sol";
import { PhishingContract } from "src/security/tx-origin/PhishingContract.sol";
import { SafeVault } from "src/security/tx-origin/SafeVault.sol";

contract TxOriginTest is Test {
    VulnerableVault vulnerableVault;
    PhishingContract phishing;
    SafeVault safeVault;

    address alice;
    address bob;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.deal(alice, 10 ether);

        vm.prank(alice);
        vulnerableVault = new VulnerableVault{ value: 5 ether }(alice);

        phishing = new PhishingContract(address(vulnerableVault), payable(bob));

        safeVault = new SafeVault{ value: 5 ether }(alice);
    }

    function test_attackerCannotWithdrawDirectly() public {
        vm.prank(bob, bob);

        vm.expectRevert(VulnerableVault.NotOwner.selector);

        vulnerableVault.withdraw(payable(bob));
    }

    function test_txOriginPhishingAttack() public {
        uint256 bobBefore = bob.balance;
        uint256 vaultBalance = address(vulnerableVault).balance;

        assertEq(address(vulnerableVault).balance, 5 ether);

        // tx.origin = alice

        // Alice
        // ↓
        // PhishingContract
        // ↓
        // VulnerableVault

        // msg.sender = PhishingContract
        // tx.origin  = Alice
        // owner      = Alice

        vm.prank(alice, alice);
        phishing.claimSomething();

        // Bob should now have stolen the vault balance.
        assertEq(address(vulnerableVault).balance, 0 ether);
        assertEq(bob.balance, bobBefore + vaultBalance);
    }

    function test_safeVaultBlocksPhishingAttack() public {
        uint256 bobBefore = bob.balance;
        uint256 vaultBalance = address(safeVault).balance;

        assertEq(address(safeVault).balance, 5 ether);

        vm.prank(bob);
        phishing.updateVault(address(safeVault));

        vm.prank(alice, alice);
        vm.expectRevert(SafeVault.Unauthorized.selector);
        phishing.claimSomething();

        // Alice → PhishingContract → SafeVault

        // msg.sender = PhishingContract
        // owner      = Alice
        //             ↓
        // Unauthorized()
        //             ↓
        // SafeVault keeps its 5 ETH
        // Bob gets nothing

        // Bob should now have stolen the vault balance.
        assertEq(address(safeVault).balance, 5 ether);
        assertEq(bob.balance, bobBefore);
    }

    function test_ownerCanWithdraw() public {
        uint256 aliceBefore = alice.balance;
        uint256 vaultBalance = address(safeVault).balance;

        assertEq(address(safeVault).balance, 5 ether);

        vm.prank(alice, alice);
        safeVault.withdraw(payable(alice));

        assertEq(address(safeVault).balance, 0 ether);
        assertEq(alice.balance, aliceBefore + 5 ether);
    }
}
