// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Spender } from "src/security/approvals/Spender.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";

contract ApprovalsTest is Test {
    using SafeERC20 for IERC20;

    Spender spender;
    MockERC20 token;

    address alice = address(0x1001);
    address bob = address(0x1002);
    address attacker = address(0x1003);
    address protocolTreasury = address(0x1004);

    function setUp() public {
        token = new MockERC20();
        spender = new Spender(token);
    }

    // This is ordering vulnerability
    // Bob spend old allowance
    //         ↓
    // Alice overwrite allowance
    //         ↓
    // Bob spend new allowance
    function test_approvalOverwriteRace() public {
        token.mint(alice, 200 ether);

        // Initial permission: Bob can spend 100.
        vm.prank(alice);
        token.approve(bob, 100 ether);

        assertEq(token.allowance(alice, bob), 100 ether);

        // Alice "submits" a change to 50,
        // but Bob's spend is ordered first.

        vm.prank(bob);
        token.transferFrom(alice, bob, 100 ether);

        assertEq(token.allowance(alice, bob), 0);

        // Then Alice's approval update lands.
        vm.prank(alice);
        token.approve(bob, 50 ether);

        assertEq(token.allowance(alice, bob), 50 ether);

        // Bob can spend another 50.
        vm.prank(bob);
        token.transferFrom(alice, bob, 50 ether);

        assertEq(token.allowance(alice, bob), 0);

        // But Bob's balance is 150 ether
        assertEq(token.balanceOf(bob), 150 ether);
    }

    // large/long-lived authority
    //         ↓
    // large blast radius if spender fails
    function test_unlimitedApprovalExpandsBlastRadius() public {
        token.mint(alice, 100 ether);

        vm.prank(alice);
        token.approve(address(spender), type(uint256).max);

        // Initial legitimate use.
        spender.pull(alice, protocolTreasury, 20 ether);

        // Much later Alice receives more tokens.
        token.mint(alice, 1000 ether);

        uint256 aliceRemaining = token.balanceOf(alice);

        // Compromised spender drains everything.
        spender.pull(alice, attacker, aliceRemaining);

        assertEq(token.balanceOf(alice), 0);
    }

    // function test_allowanceDecreaseByDeltaAvoidsOverwriteSemantics() public {
    //     token.mint(alice, 200 ether);

    //     vm.prank(alice);
    //     token.approve(bob, 100 ether);

    //     assertEq(token.allowance(alice, bob), 100 ether);

    //     // Bob spends part of the existing allowance first.
    //     vm.prank(bob);
    //     token.transferFrom(alice, bob, 40 ether);

    //     assertEq(token.allowance(alice, bob), 60 ether);

    //     // Alice reduces whatever allowance remains by 50.
    //     vm.prank(alice);
    //     // IERC20(address(token)).safeDecreaseAllowance(bob, 50 ether);
    //     SafeERC20.safeDecreaseAllowance(token, bob, 50 ether);

    //     assertEq(token.allowance(alice, bob), 10 ether);
    // }

    // EXACT APPROVAL
    // ──────────────
    // approve(20)

    // pull 20
    //     ↓
    // allowance = 0

    // receive 1000 more tokens
    //     ↓
    // spender has no authority ✅
    function test_exactApprovalLimitsSpenderAuthority() public {
        token.mint(alice, 100 ether);

        vm.prank(alice);
        token.approve(address(spender), 20 ether);

        assertEq(token.allowance(alice, address(spender)), 20 ether);

        // Intended operation.
        spender.pull(alice, protocolTreasury, 20 ether);

        assertEq(token.allowance(alice, address(spender)), 0);

        assertEq(token.balanceOf(alice), 80 ether);

        // Alice later receives substantially more funds.
        token.mint(alice, 1000 ether);

        assertEq(token.balanceOf(alice), 1080 ether);

        // Old approval provides no authority over them.
        vm.expectRevert();

        spender.pull(alice, attacker, 1 ether);

        assertEq(token.balanceOf(attacker), 0);

        assertEq(token.balanceOf(alice), 1080 ether);
    }

    // UNLIMITED APPROVAL
    // ──────────────────
    // approve(MAX)

    // pull 20
    //     ↓
    // allowance still MAX

    // receive 1000 more tokens
    //     ↓
    // spender can drain them ❌
    function test_infiniteAllowanceIsNotDecremented() public {
        token.mint(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);

        vm.prank(alice);
        token.approve(address(spender), type(uint256).max);

        assertEq(token.allowance(alice, address(spender)), type(uint256).max);

        spender.pull(alice, protocolTreasury, 100 ether);

        assertEq(token.balanceOf(alice), 0);

        assertEq(token.allowance(alice, address(spender)), type(uint256).max);
    }
}
