// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockFalseReturnERC20 } from "test/mocks/MockFalseReturnERC20.sol";
import { MockFeeOnTransferERC20 } from "test/mocks/MockFeeOnTransferERC20.sol";
import { MockNoReturnERC20 } from "test/mocks/MockNoReturnERC20.sol";
import { TokenTransfer, IERC20, SafeERC20 } from "src/common/token/TokenTransfer.sol";
import { TokenTransferHarness } from "test/helpers/TokenTransferHarness.sol";

contract TokenTransferTest is Test {
    MockERC20 token;
    MockFeeOnTransferERC20 tokenWithFee;
    MockFalseReturnERC20 tokenWithFalseReturn;
    MockNoReturnERC20 tokenWithNoReturn;

    TokenTransferHarness harness;
    address user = address(0x1001);
    address receiver = address(0x1002);
    uint256 amount = 1000 ether;

    function setUp() public {
        token = new MockERC20();
        harness = new TokenTransferHarness();

        token.mint(user, amount);

        vm.prank(user);
        token.approve(address(harness), amount);

        tokenWithFee = new MockFeeOnTransferERC20(address(this), 10 wei);
        tokenWithFalseReturn = new MockFalseReturnERC20();
        tokenWithNoReturn = new MockNoReturnERC20();
    }

    function test_PullExact_TransfersRequestedAmount() public {
        assertEq(token.balanceOf(user), amount);
        assertEq(token.balanceOf(address(harness)), 0);

        uint256 received = harness.pullExact(token, user, amount);

        assertEq(received, amount);
        assertEq(token.balanceOf(user), 0);
        assertEq(token.balanceOf(address(harness)), amount);
    }

    function test_PullExact_RevertsWhenZeroToken() public {
        vm.expectRevert(TokenTransfer.ZeroToken.selector);
        uint256 received = harness.pullExact(IERC20(address(0)), user, amount);

        assertEq(received, 0);
        assertEq(token.balanceOf(user), amount);
        assertEq(token.balanceOf(address(harness)), 0);
    }

    function test_PullExact_FeeOnTransferToken_RevertsAndRollsBack() public {
        tokenWithFee.mint(user, amount);

        vm.prank(user);
        tokenWithFee.approve(address(harness), amount);

        uint256 expectedReceived = amount - 10 wei;

        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.UnexpectedTransferAmount.selector, amount, expectedReceived)
        );
        harness.pullExact(tokenWithFee, user, amount);

        assertEq(tokenWithFee.balanceOf(user), amount);
        assertEq(tokenWithFee.balanceOf(address(harness)), 0);
        assertEq(tokenWithFee.balanceOf(address(tokenWithFee)), 0);

        // transferFrom allowance reduction was also rolled back.
        assertEq(tokenWithFee.allowance(user, address(harness)), amount);
    }

    function test_PullBalanceDelta_FeeOnTransferToken() public {
        tokenWithFee.mint(user, amount);
        vm.prank(user);
        tokenWithFee.approve(address(harness), amount);

        uint256 expectedReceived = amount - 10 wei;

        uint256 received = harness.pullBalanceDelta(tokenWithFee, user, amount);

        assertEq(received, expectedReceived);
        assertEq(tokenWithFee.balanceOf(user), 0);
        assertEq(tokenWithFee.balanceOf(address(harness)), expectedReceived);
        assertEq(tokenWithFee.balanceOf(address(tokenWithFee)), 10 wei);
    }

    function test_PullExact_RevertsWhenFalseReturnToken() public {
        tokenWithFalseReturn.mint(user, amount);
        vm.prank(user);
        tokenWithFalseReturn.approve(address(harness), amount);

        vm.expectRevert();
        harness.pullExact(tokenWithFalseReturn, user, amount);
    }

    function test_PullExact_SupportsNoReturnToken() public {
        tokenWithNoReturn.mint(user, amount);
        vm.prank(user);
        SafeERC20.forceApprove(tokenWithNoReturn, address(harness), amount);

        uint256 received = harness.pullExact(tokenWithNoReturn, user, amount);

        assertEq(received, amount);
        assertEq(tokenWithNoReturn.balanceOf(user), 0);
        assertEq(tokenWithNoReturn.balanceOf(address(harness)), amount);
    }

    function test_PullBalanceDelta_RevertsWhenZeroToken() public {
        vm.expectRevert(TokenTransfer.ZeroToken.selector);
        uint256 received = harness.pullBalanceDelta(IERC20(address(0)), user, amount);

        assertEq(received, 0);
        assertEq(token.balanceOf(user), amount);
        assertEq(token.balanceOf(address(harness)), 0);
    }
}

