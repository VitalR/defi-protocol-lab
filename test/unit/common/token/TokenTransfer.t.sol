// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockFalseReturnERC20 } from "test/mocks/MockFalseReturnERC20.sol";
import { MockFeeOnTransferERC20 } from "test/mocks/MockFeeOnTransferERC20.sol";
import { MockNoReturnERC20 } from "test/mocks/MockNoReturnERC20.sol";
import { MockAdditionalSenderFeeERC20 } from "test/mocks/MockAdditionalSenderFeeERC20.sol";
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
            abi.encodeWithSelector(TokenTransfer.UnexpectedAmountReceived.selector, amount, expectedReceived)
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

    function test_PushExact_TransfersRequestedAmount() public {
        assertEq(token.balanceOf(receiver), 0);
        assertEq(token.balanceOf(address(harness)), 0);

        token.mint(address(harness), amount);
        assertEq(token.balanceOf(address(harness)), amount);

        (uint256 spent, uint256 received) = harness.pushExact(token, receiver, amount);

        assertEq(spent, amount);
        assertEq(received, amount);
        assertEq(token.balanceOf(receiver), amount);
        assertEq(token.balanceOf(address(harness)), 0);
    }

    function test_PushExact_RevertsWhenRecipientReceivesLess() public {
        tokenWithFee.mint(address(harness), amount);

        uint256 expectedReceived = amount - 10 wei;

        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.UnexpectedAmountReceived.selector, amount, expectedReceived)
        );
        harness.pushExact(tokenWithFee, receiver, amount);

        assertEq(tokenWithFee.balanceOf(address(harness)), amount);
        assertEq(tokenWithFee.balanceOf(receiver), 0);
        assertEq(tokenWithFee.balanceOf(address(tokenWithFee)), 0);
    }

    function test_PushExact_RevertsWhenZeroToken() public {
        token.mint(address(harness), amount);
        assertEq(token.balanceOf(address(harness)), amount);
        assertEq(token.balanceOf(receiver), 0);

        vm.expectRevert(TokenTransfer.ZeroToken.selector);
        harness.pushExact(IERC20(address(0)), receiver, amount);

        assertEq(token.balanceOf(address(harness)), amount);
        assertEq(token.balanceOf(receiver), 0);
    }

    function test_PushBalanceDelta_RevertsWhenZeroToken() public {
        token.mint(address(harness), amount);
        assertEq(token.balanceOf(address(harness)), amount);
        assertEq(token.balanceOf(receiver), 0);

        vm.expectRevert(TokenTransfer.ZeroToken.selector);
        harness.pushBalanceDelta(IERC20(address(0)), receiver, amount);

        assertEq(token.balanceOf(address(harness)), amount);
        assertEq(token.balanceOf(receiver), 0);
    }

    function test_PushBalanceDelta_ReturnsSpentAndReceived() public {
        tokenWithFee.mint(address(harness), amount);

        (uint256 spent, uint256 received) = harness.pushBalanceDelta(tokenWithFee, receiver, amount);

        assertEq(spent, amount);
        assertEq(received, amount - 10 wei);

        assertEq(tokenWithFee.balanceOf(address(harness)), 0);
        assertEq(tokenWithFee.balanceOf(receiver), amount - 10 wei);
        assertEq(tokenWithFee.balanceOf(address(tokenWithFee)), 10 wei);
    }

    function test_PushExact_RevertsWhenFalseReturnToken() public {
        tokenWithFalseReturn.mint(address(harness), amount);

        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(tokenWithFalseReturn))
        );
        harness.pushExact(tokenWithFalseReturn, receiver, amount);
    }

    function test_PushExact_SupportsNoReturnToken() public {
        assertEq(tokenWithNoReturn.balanceOf(receiver), 0);
        assertEq(tokenWithNoReturn.balanceOf(address(harness)), 0);

        tokenWithNoReturn.mint(address(harness), amount);
        assertEq(tokenWithNoReturn.balanceOf(address(harness)), amount);

        (uint256 spent, uint256 received) = harness.pushExact(tokenWithNoReturn, receiver, amount);

        assertEq(spent, amount);
        assertEq(received, amount);
        assertEq(tokenWithNoReturn.balanceOf(receiver), amount);
        assertEq(tokenWithNoReturn.balanceOf(address(harness)), 0);
    }

    function test_PushBalanceDelta_AdditionalSenderFee() public {
        uint256 fee = 10 wei;
        address feeCollector = address(0xFEE);

        MockAdditionalSenderFeeERC20 senderFeeToken = new MockAdditionalSenderFeeERC20(feeCollector, fee);

        senderFeeToken.mint(address(harness), amount + fee);

        (uint256 spent, uint256 received) = harness.pushBalanceDelta(senderFeeToken, receiver, amount);

        assertEq(spent, amount + fee);
        assertEq(received, amount);

        assertEq(senderFeeToken.balanceOf(address(harness)), 0);
        assertEq(senderFeeToken.balanceOf(receiver), amount);
        assertEq(senderFeeToken.balanceOf(feeCollector), fee);
    }

    function test_PushExact_RevertsWhenSenderPaysAdditionalFee() public {
        uint256 fee = 10 wei;
        address feeCollector = address(0xFEE);

        MockAdditionalSenderFeeERC20 senderFeeToken = new MockAdditionalSenderFeeERC20(feeCollector, fee);

        senderFeeToken.mint(address(harness), amount + fee);

        vm.expectRevert(abi.encodeWithSelector(TokenTransfer.UnexpectedAmountSpent.selector, amount, amount + fee));

        harness.pushExact(senderFeeToken, receiver, amount);

        // The complete transfer, including its fee, is rolled back.
        assertEq(senderFeeToken.balanceOf(address(harness)), amount + fee);
        assertEq(senderFeeToken.balanceOf(receiver), 0);
        assertEq(senderFeeToken.balanceOf(feeCollector), 0);
    }

    function test_PushExact_RevertsWhenZeroRecipient() public {
        assertEq(token.balanceOf(receiver), 0);
        assertEq(token.balanceOf(address(harness)), 0);

        token.mint(address(harness), amount);
        assertEq(token.balanceOf(address(harness)), amount);

        vm.expectRevert(TokenTransfer.ZeroRecipient.selector);
        (uint256 spent, uint256 received) = harness.pushExact(token, address(0), amount);

        assertEq(token.balanceOf(receiver), 0);
        assertEq(token.balanceOf(address(harness)), amount);
    }

    function test_PushExact_RevertsWhenSelfTransfer() public {
        assertEq(token.balanceOf(receiver), 0);
        assertEq(token.balanceOf(address(harness)), 0);

        token.mint(address(harness), amount);
        assertEq(token.balanceOf(address(harness)), amount);

        vm.expectRevert(TokenTransfer.SelfTransfer.selector);
        (uint256 spent, uint256 received) = harness.pushExact(token, address(harness), amount);

        assertEq(token.balanceOf(receiver), 0);
        assertEq(token.balanceOf(address(harness)), amount);
    }

    function test_PushExact_ZeroAmountReturnsZeroDeltas() public {
        (uint256 spent, uint256 received) = harness.pushExact(token, receiver, 0);

        assertEq(spent, 0);
        assertEq(received, 0);
    }
}

