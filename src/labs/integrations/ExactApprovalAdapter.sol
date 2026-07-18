// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ITokenSpender {
    function spend(IERC20 token, uint256 amount) external;
}

contract ExactApprovalAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroToken();
    error ZeroSpender();
    error ZeroAmount();
    error UnexpectedAmountSpent(uint256 expected, uint256 actual);

    address public immutable spender;

    constructor(address _spender) {
        require(_spender != address(0), ZeroSpender());
        spender = _spender;
    }

    function executeExact(IERC20 token, uint256 amount) external nonReentrant returns (uint256 spent) {
        require(address(token) != address(0), ZeroToken());
        require(amount > 0, ZeroAmount());

        uint256 balanceBefore = token.balanceOf(address(this));

        token.forceApprove(spender, amount); // Grant permission

        ITokenSpender(spender).spend(token, amount); // Use permission

        token.forceApprove(spender, 0); // Revoke remaining permission

        uint256 balanceAfter = token.balanceOf(address(this));
        spent = balanceBefore - balanceAfter;

        if (spent != amount) {
            revert UnexpectedAmountSpent(amount, spent);
        }
    }
}
