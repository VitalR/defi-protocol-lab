// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { ExactApprovalAdapter, IERC20 } from "src/labs/integrations/ExactApprovalAdapter.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockZeroFirstERC20 } from "test/mocks/MockZeroFirstERC20.sol";
import { MockPullSpender } from "test/mocks/MockPullSpender.sol";

contract ExactApprovalAdapterTest is Test {
    ExactApprovalAdapter adapter;
    MockERC20 token;
    MockZeroFirstERC20 tokenZeroFirst;
    MockPullSpender spender;

    address user = address(0x1001);
    address receiver = address(0x1002);
    uint256 amount = 1000 ether;

    function setUp() public {
        spender = new MockPullSpender();
        adapter = new ExactApprovalAdapter(address(spender));
        token = new MockERC20();
        tokenZeroFirst = new MockZeroFirstERC20();
    }

    function test_DeployAdapter() public {
        assertEq(adapter.spender(), address(spender));
    }

    function test_DeployAdapter_RevertsZeroSpender() public {
        vm.expectRevert(ExactApprovalAdapter.ZeroSpender.selector);
        new ExactApprovalAdapter(address(0));
    }

    function test_ExecuteExact_RevertsZeroToken() public {
        vm.expectRevert(ExactApprovalAdapter.ZeroToken.selector);
        adapter.executeExact(IERC20(address(0)), amount);
    }

    function test_ExecuteExact_RevertsZeroAmount() public {
        vm.expectRevert(ExactApprovalAdapter.ZeroAmount.selector);
        adapter.executeExact(IERC20(token), 0);
    }

    function test_ExecuteExact_ExactSpenderConsumesAmount() public {
        token.mint(address(adapter), amount);

        assertEq(token.balanceOf(address(adapter)), amount);
        assertEq(token.balanceOf(address(spender)), 0);

        uint256 spent = adapter.executeExact(token, amount);

        assertEq(spent, amount);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(address(spender)), amount);

        assertEq(token.allowance(address(adapter), address(spender)), 0);
    }

    function test_ExecuteExact_SupportsZeroFirstToken() public {
        tokenZeroFirst.mint(address(adapter), amount);

        // Simulate a residual allowance from an earlier operation.
        vm.prank(address(adapter));
        tokenZeroFirst.approve(address(spender), 1);

        assertEq(tokenZeroFirst.allowance(address(adapter), address(spender)), 1);

        uint256 spent = adapter.executeExact(tokenZeroFirst, amount);

        assertEq(spent, amount);
        assertEq(tokenZeroFirst.balanceOf(address(adapter)), 0);
        assertEq(tokenZeroFirst.balanceOf(address(spender)), amount);
        assertEq(tokenZeroFirst.allowance(address(adapter), address(spender)), 0);
    }
}

// constructor stores the spender;
// zero spender reverts;
// zero token reverts;
// zero amount reverts;
// exact spender consumes the amount;
// final allowance is zero;
// zero-first token works through forceApprove;
// returned spent value is correct.
