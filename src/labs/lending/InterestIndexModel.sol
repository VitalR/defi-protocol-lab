// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";

contract InterestIndexModel {
    error InvalidTimestamp(uint256 timestamp, uint256 lastUpdateTimestamp);
    error InvalidIndex(uint256 index);

    uint256 public constant SECONDS_PER_YEAR = 365 days;

    uint256 public borrowIndex;
    uint256 public lastUpdateTimestamp;

    constructor() {
        borrowIndex = 1e18;
        lastUpdateTimestamp = block.timestamp;
    }

    // Borrow-index growth rounds upward to avoid understating accrued debt.
    // The two-step calculation may introduce a small conservative rounding bias.
    function previewBorrowIndex(uint256 annualRateWad, uint256 timestamp) public view returns (uint256) {
        require(timestamp >= lastUpdateTimestamp, InvalidTimestamp(timestamp, lastUpdateTimestamp));

        uint256 elapsed = timestamp - lastUpdateTimestamp;

        if (elapsed == 0 || annualRateWad == 0) {
            return borrowIndex;
        }

        // growth =
        // borrowIndex
        // × annualRateWad
        // × elapsed
        // ----------------
        // 1e18 × YEAR

        uint256 growth = Math.mulDiv(borrowIndex, annualRateWad, 1e18, Math.Rounding.Ceil);

        growth = Math.mulDiv(growth, elapsed, SECONDS_PER_YEAR, Math.Rounding.Ceil);

        // newIndex = borrowIndex + growth
        return borrowIndex + growth;
    }

    function updateBorrowIndex(uint256 annualRateWad) external returns (uint256 newIndex) {
        newIndex = previewBorrowIndex(annualRateWad, block.timestamp);

        borrowIndex = newIndex;
        lastUpdateTimestamp = block.timestamp;
    }

    // scaledDebt
    // → user ownership/accounting units

    // borrowIndex
    // → global time-dependent multiplier

    // actualDebt
    // → derived economic debt

    function toScaledDebt(uint256 actualDebt, uint256 index) public pure returns (uint256 scaledDebt) {
        require(index >= 1e18, InvalidIndex(index));

        return Math.mulDiv(actualDebt, 1e18, index, Math.Rounding.Ceil);
    }

    function fromScaledDebt(uint256 scaledDebt, uint256 index) public pure returns (uint256 actualDebt) {
        require(index >= 1e18, InvalidIndex(index));

        return Math.mulDiv(scaledDebt, index, 1e18, Math.Rounding.Ceil);
    }

    function scaledDebtForBorrow(uint256 borrowAmount, uint256 index) public pure returns (uint256) {
        require(index >= 1e18, InvalidIndex(index));

        return Math.mulDiv(borrowAmount, 1e18, index, Math.Rounding.Ceil);
    }

    function scaledDebtForRepay(uint256 repayAmount, uint256 index) public pure returns (uint256) {
        require(index >= 1e18, InvalidIndex(index));

        return Math.mulDiv(repayAmount, 1e18, index, Math.Rounding.Floor);
    }
}
