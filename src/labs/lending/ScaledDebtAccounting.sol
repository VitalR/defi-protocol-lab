// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract ScaledDebtAccounting {
    error ZeroAmount();
    error InvalidIndex(uint256 index);
    error IndexCannotDecrease(uint256 currentIndex, uint256 newIndex);
    error RepayExceedsDebt(uint256 requested, uint256 currentDebt);
    error RepayTooSmall(uint256 amount);

    uint256 public borrowIndex;
    uint256 public totalScaledDebt;

    mapping(address user => uint256 scaledDebt) private _scaledDebt;

    constructor() {
        borrowIndex = 1e18;
    }

    function addDebt(address user, uint256 amount) external {
        require(amount > 0, ZeroAmount());

        uint256 scaledDelta = Math.mulDiv(amount, 1e18, borrowIndex, Math.Rounding.Ceil);

        _scaledDebt[user] += scaledDelta;
        totalScaledDebt += scaledDelta;
    }

    function repayDebt(address user, uint256 amount) external {
        require(amount > 0, ZeroAmount());

        uint256 currentDebt = debtOf(user);

        require(amount <= currentDebt, RepayExceedsDebt(amount, currentDebt));

        uint256 scaledDebt = _scaledDebt[user];
        if (amount == currentDebt) {
            _scaledDebt[user] = 0;
            totalScaledDebt -= scaledDebt;
            return;
        }

        uint256 scaledDelta = Math.mulDiv(amount, 1e18, borrowIndex, Math.Rounding.Floor);

        require(scaledDelta != 0, RepayTooSmall(amount));

        _scaledDebt[user] -= scaledDelta;
        totalScaledDebt -= scaledDelta;
    }

    function setBorrowIndex(uint256 newIndex) external {
        require(newIndex >= 1e18, InvalidIndex(newIndex));
        require(newIndex >= borrowIndex, IndexCannotDecrease(borrowIndex, newIndex));

        borrowIndex = newIndex;
    }

    function scaledDebtOf(address user) external view returns (uint256) {
        return _scaledDebt[user];
    }

    function debtOf(address user) public view returns (uint256) {
        return Math.mulDiv(_scaledDebt[user], borrowIndex, 1e18, Math.Rounding.Ceil);
    }

    function totalDebt() public view returns (uint256) {
        return Math.mulDiv(totalScaledDebt, borrowIndex, 1e18, Math.Rounding.Ceil);
    }
}
