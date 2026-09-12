// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Math } from "src/common/math/DecimalMath.sol";

contract LiquidityIndexModel {
    error InvalidUtilization(uint256 utilization);
    error InvalidReserveFactor(uint256 reserveFactor);

    uint256 internal constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    uint256 public liquidityIndex;
    uint256 public lastUpdateTimestamp;

    constructor() {
        liquidityIndex = WAD;
        lastUpdateTimestamp = block.timestamp;
    }

    // liquidityRate
    // =
    // borrowRate
    // × utilization
    // × (1 - reserveFactor)
    function liquidityRate(uint256 borrowRate, uint256 utilization, uint256 reserveFactor)
        public
        pure
        returns (uint256)
    {
        require(utilization <= WAD, InvalidUtilization(utilization));
        require(reserveFactor <= WAD, InvalidReserveFactor(reserveFactor));

        if (utilization == 0) return 0;

        uint256 grossRate = Math.mulDiv(borrowRate, utilization, WAD, Math.Rounding.Trunc);

        uint256 share = WAD - reserveFactor;

        return Math.mulDiv(grossRate, share, WAD, Math.Rounding.Trunc);
    }

    // newLiquidityIndex
    // =
    // oldIndex
    // +
    // oldIndex × liquidityRate × elapsed / YEAR
    function currentLiquidityIndex(uint256 borrowRate, uint256 utilization, uint256 reserveFactor)
        public
        view
        returns (uint256)
    {
        uint256 rate = liquidityRate(borrowRate, utilization, reserveFactor);

        uint256 elapsed = block.timestamp - lastUpdateTimestamp;

        if (elapsed == 0) return liquidityIndex;

        uint256 indexGrowth = Math.mulDiv(liquidityIndex, rate, WAD, Math.Rounding.Floor);

        indexGrowth = Math.mulDiv(indexGrowth, elapsed, SECONDS_PER_YEAR, Math.Rounding.Floor);

        return liquidityIndex + indexGrowth;
    }

    function accrue(uint256 borrowRate, uint256 utilization, uint256 reserveFactor) external {
        uint256 newIndex = currentLiquidityIndex(borrowRate, utilization, reserveFactor);

        liquidityIndex = newIndex;
        lastUpdateTimestamp = block.timestamp;
    }
}
