// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockPullSpender {
    using SafeERC20 for IERC20;

    error NotSupportedSpendMode();

    // Exact: pulls exactly amount;
    // Partial: pulls amount / 2;
    // Excessive: attempts to pull amount + 1.
    enum SpendMode {
        Exact,
        Partial,
        Excessive
    }

    SpendMode private _spendMode;

    constructor() {
        _spendMode = SpendMode.Exact;
    }

    function setSpendMode(SpendMode mode) external {
        _spendMode = mode;
    }

    function spend(IERC20 token, uint256 amount) external {
        uint256 pullAmount;

        if (_spendMode == SpendMode.Exact) {
            pullAmount = amount;
        } else if (_spendMode == SpendMode.Partial) {
            pullAmount = amount / 2;
        } else {
            pullAmount = amount + 1;
        }

        token.safeTransferFrom(msg.sender, address(this), pullAmount);
    }
}
