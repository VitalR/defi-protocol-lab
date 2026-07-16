// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library TokenTransfer {
    using SafeERC20 for IERC20;

    error ZeroToken();
    error ZeroRecipient();
    error SelfTransfer();
    error UnexpectedAmountSpent(uint256 expected, uint256 actual);
    error UnexpectedAmountReceived(uint256 expected, uint256 actual);

    function pullExact(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        require(address(token) != address(0), ZeroToken());

        uint256 amountBefore = token.balanceOf(address(this));

        token.safeTransferFrom(from, address(this), amount);

        received = token.balanceOf(address(this)) - amountBefore;

        if (received != amount) revert UnexpectedAmountReceived(amount, received);
    }

    function pullBalanceDelta(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        require(address(token) != address(0), ZeroToken());

        uint256 balanceBefore = token.balanceOf(address(this));

        token.safeTransferFrom(from, address(this), amount);

        received = token.balanceOf(address(this)) - balanceBefore;
    }

    function pushExact(IERC20 token, address to, uint256 amount) internal returns (uint256 spent, uint256 received) {
        (spent, received) = pushBalanceDelta(token, to, amount);

        if (spent != amount) {
            revert UnexpectedAmountSpent(amount, spent);
        }

        if (received != amount) {
            revert UnexpectedAmountReceived(amount, received);
        }
    }

    function pushBalanceDelta(IERC20 token, address to, uint256 amount)
        internal
        returns (uint256 spent, uint256 received)
    {
        require(address(token) != address(0), ZeroToken());
        require(to != address(0), ZeroRecipient());
        require(to != address(this), SelfTransfer());

        uint256 senderBalanceBefore = token.balanceOf(address(this));
        uint256 receiverBalanceBefore = token.balanceOf(to);

        token.safeTransfer(to, amount);

        uint256 senderBalanceAfter = token.balanceOf(address(this));
        uint256 receiverBalanceAfter = token.balanceOf(to);

        spent = senderBalanceBefore - senderBalanceAfter;
        received = receiverBalanceAfter - receiverBalanceBefore;
    }
}
