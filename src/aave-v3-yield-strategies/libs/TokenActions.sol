// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TokenActions
/// @notice Small helpers for common ERC-20 flows in DeFi integrations (pulling funds and setting allowances).
/// @dev Compatible with OpenZeppelin v5. Uses SafeERC20.forceApprove internally to handle
///      USDT-like tokens that require a 0 -> N approval path.
library TokenActions {
    using SafeERC20 for IERC20;

    /// @notice Pull tokens from `from` into this contract and return the *actual* amount received.
    /// @dev Supports fee-on-transfer tokens by measuring balance delta; if the token takes a fee,
    ///      `received` will be lower than `amount`.
    /// @param token The ERC-20 to be transferred.
    /// @param from The address to pull tokens from (caller in most flows).
    /// @param amount The requested transfer amount.
    /// @return received The actual amount received by this contract.
    function pullFrom(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBal = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        unchecked {
            received = token.balanceOf(address(this)) - beforeBal;
        }
    }

    /// @notice Pull the *entire* balance of `token` from `from` into this contract.
    /// @param token The ERC-20 to be transferred.
    /// @param from The address to pull tokens from.
    /// @return received The actual amount received by this contract.
    function pullAllFrom(IERC20 token, address from) internal returns (uint256 received) {
        uint256 bal = token.balanceOf(from);
        if (bal == 0) return 0;
        received = pullFrom(token, from, bal);
    }

    /// @notice Force-approve `spender` to spend exactly `amount`.
    /// @dev Uses OZ v5 `forceApprove`, which tries `approve(amount)` and falls back to `approve(0)` then
    /// `approve(amount)`
    ///      for USDT-like tokens that revert when changing non-zero allowances directly.
    /// @param token The ERC-20 token whose allowance is being set.
    /// @param spender The address that will be allowed to spend.
    /// @param amount The exact allowance to set.
    function approveExact(IERC20 token, address spender, uint256 amount) internal {
        token.forceApprove(spender, amount);
    }

    /// @notice Approve unlimited allowance for `spender` (uint256 max).
    /// @param token The ERC-20 token whose allowance is being set.
    /// @param spender The address that will be allowed to spend.
    function approveMax(IERC20 token, address spender) internal {
        token.forceApprove(spender, type(uint256).max);
    }

    /// @notice Convenience: pull → approve exact → return actual received.
    /// @dev Good for repay/supply flows; handles fee-on-transfer tokens safely.
    /// @param token The ERC-20 to pull/approve.
    /// @param from The address to pull tokens from.
    /// @param spender The address to approve for spending.
    /// @param amount The requested amount to pull (actual received may be lower).
    /// @return received The actual amount received and approved.
    function pullAndApproveExact(IERC20 token, address from, address spender, uint256 amount)
        internal
        returns (uint256 received)
    {
        received = pullFrom(token, from, amount);
        token.forceApprove(spender, received);
    }

    /// @notice Convenience: pull ALL → approve exact → return actual received.
    /// @param token The ERC-20 to pull/approve.
    /// @param from The address to pull tokens from.
    /// @param spender The address to approve for spending.
    /// @return received The actual amount received and approved.
    function pullAllAndApproveExact(IERC20 token, address from, address spender) internal returns (uint256 received) {
        received = pullAllFrom(token, from);
        if (received > 0) token.forceApprove(spender, received);
    }
}
