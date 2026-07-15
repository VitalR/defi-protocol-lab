// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { SafeERC20, IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

library TokenTransfer {
    using SafeERC20 for IERC20;

    error ZeroToken();
    error UnexpectedTransferAmount(uint256 expected, uint256 actual);

    function pullExact(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        require(address(token) != address(0), ZeroToken());

        uint256 amountBefore = token.balanceOf(address(this));

        token.safeTransferFrom(from, address(this), amount);

        received = token.balanceOf(address(this)) - amountBefore;

        if (received != amount) revert UnexpectedTransferAmount(amount, received);
    }

    function pullBalanceDelta(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        require(address(token) != address(0), ZeroToken());

        uint256 balanceBefore = token.balanceOf(address(this));

        token.safeTransferFrom(from, address(this), amount);

        received = token.balanceOf(address(this)) - balanceBefore;
    }
}
