// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { TokenTransfer } from "src/common/token/TokenTransfer.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Educational contract containing intentionally vulnerable code.
/// @dev Must not be deployed or used in production.
contract TokenBank is ReentrancyGuard {
    error InsufficientBalance(uint256 available, uint256 requested);

    mapping(address user => mapping(address token => uint256 amount)) public balanceOf;

    function deposit(address token, uint256 amount) external {
        uint256 received = TokenTransfer.pullBalanceDelta(IERC20(token), msg.sender, amount);

        balanceOf[msg.sender][token] += received;
    }

    function withdrawVulnerable(address token, uint256 amount) external {
        uint256 currentBalance = balanceOf[msg.sender][token];

        if (currentBalance < amount) revert InsufficientBalance(currentBalance, amount);

        TokenTransfer.pushBalanceDelta(IERC20(token), msg.sender, amount);

        // Writes a value calculated before the external call.
        balanceOf[msg.sender][token] = currentBalance - amount;
    }

    function withdrawProtected(address token, uint256 amount) external nonReentrant {
        balanceOf[msg.sender][token] -= amount;

        TokenTransfer.pushExact(IERC20(token), msg.sender, amount);
    }
}
