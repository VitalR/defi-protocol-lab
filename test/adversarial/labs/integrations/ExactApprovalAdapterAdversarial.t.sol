// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { ExactApprovalAdapter, IERC20 } from "src/labs/integrations/ExactApprovalAdapter.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockZeroFirstERC20 } from "test/mocks/MockZeroFirstERC20.sol";
import { MockPullSpender } from "test/mocks/MockPullSpender.sol";
import { MockCallbackERC20, ERC20Reentrant } from "test/mocks/MockCallbackERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract ExactApprovalAdapterAdversarialTest is Test {
    ExactApprovalAdapter adapter;
    MockERC20 token;
    MockZeroFirstERC20 tokenZeroFirst;
    MockCallbackERC20 tokenCallback;
    MockPullSpender spender;

    address user = address(0x1001);
    address receiver = address(0x1002);
    uint256 amount = 1000 ether;

    function setUp() public {
        spender = new MockPullSpender();
        adapter = new ExactApprovalAdapter(address(spender));
        token = new MockERC20();
        tokenZeroFirst = new MockZeroFirstERC20();
        tokenCallback = new MockCallbackERC20();
    }

    // Spender cannot take more than approved
    function test_ExecuteExact_BlocksExcessiveSpend() public {
        spender.setSpendMode(MockPullSpender.SpendMode.Excessive);

        token.mint(address(adapter), amount);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(spender), amount, amount + 1
            )
        );

        adapter.executeExact(token, amount);

        assertEq(token.balanceOf(address(adapter)), amount);
        assertEq(token.balanceOf(address(spender)), 0);
        assertEq(token.allowance(address(adapter), address(spender)), 0);
    }

    // Exact operation cannot silently consume less
    // Approval and transfers do not remain partially applied
    function test_ExecuteExact_RevertsOnPartialSpend() public {
        spender.setSpendMode(MockPullSpender.SpendMode.Partial);

        token.mint(address(adapter), amount);

        vm.expectRevert(abi.encodeWithSelector(ExactApprovalAdapter.UnexpectedAmountSpent.selector, amount, amount / 2));

        adapter.executeExact(token, amount);

        // The partial transfer was rolled back.
        assertEq(token.balanceOf(address(adapter)), amount);
        assertEq(token.balanceOf(address(spender)), 0);
        assertEq(token.allowance(address(adapter), address(spender)), 0);
    }

    // External spender/token cannot enter the adapter again
    function test_ExecuteExact_BlocksReentrancy() public {
        tokenCallback.mint(address(adapter), amount);

        tokenCallback.scheduleReenter(
            ERC20Reentrant.Type.After,
            address(adapter),
            abi.encodeCall(ExactApprovalAdapter.executeExact, (IERC20(address(tokenCallback)), amount))
        );

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);

        adapter.executeExact(tokenCallback, amount);

        // Callback failure propagates, reverting the outer operation.
        assertEq(tokenCallback.balanceOf(address(adapter)), amount);
        assertEq(tokenCallback.balanceOf(address(spender)), 0);
        assertEq(tokenCallback.allowance(address(adapter), address(spender)), 0);
    }
}

// These simulate a hostile or abnormal counterparty:

// spender tries to take amount + 1;
// spender takes only half and leaves residual allowance;
// spender attempts reentrancy;
// spender attempts to drain tokens after execution;
// spender ignores the supplied amount;
// callback attempts another adapter operation.
