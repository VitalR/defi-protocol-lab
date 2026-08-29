// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";

contract InterestRateModel {
    error InvalidUtilization(uint256 utilization);

    uint256 public constant BASE_RATE = 0.02e18; // 2%
    uint256 public constant SLOPE1 = 0.04e18; // 4%;  slope1 - pre-kink slope
    uint256 public constant SLOPE2 = 0.75e18; // 75%; slope2 - post-kink slope
    uint256 public constant OPTIMAL_UTILIZATION = 0.8e18; // 80%
    uint256 public constant RESERVE_FACTOR = 0.1e18; // 10%

    // U = totalDebt / (availableLiquidity + totalDebt)
    function utilization(uint256 availableLiquidity, uint256 totalDebt) public pure returns (uint256 utilizationWad) {
        // Empty reserve: availableLiquidity == 0 || totalDebt == 0, nulls - normal reserve state
        // if available = 0 && debt = 0 => utilization: 0%
        // if available = 1000 && debt = 0 => utilization: 0%
        // if available = 0 && debt = 1000 => utilization: 100%

        uint256 totalLiquidity = availableLiquidity + totalDebt;

        if (totalLiquidity == 0) return 0;

        return utilizationWad = DecimalMath.ratioWad(totalDebt, totalLiquidity, Math.Rounding.Trunc);
    }

    // Kinked borrow-rate curve:
    // - up to optimal utilization: baseRate + slope1 * normalized utilization
    // - above optimal utilization: baseRate + slope1 + slope2 * normalized excess utilization
    function borrowRate(uint256 utilizationWad) public pure returns (uint256 rateWad) {
        require(utilizationWad <= 1e18, InvalidUtilization(utilizationWad));

        if (utilizationWad <= OPTIMAL_UTILIZATION) {
            uint256 slopeContribution = Math.mulDiv(SLOPE1, utilizationWad, OPTIMAL_UTILIZATION, Math.Rounding.Trunc);
            return BASE_RATE + slopeContribution;
        }

        // general pattern
        // (x - min)
        // ---------
        // (max - min)
        // where x inside [min, max] normalized to [0, 1]

        // x   = current utilization
        // min = optimal utilization
        // max = 100%

        // Utilization:
        // 80%          90%          100%
        // |-------------|-------------|
        // 0%            50%          100%
        // post-kink progress
        // Which piece of post-kink segment from 80% to 100% we have already done?
        uint256 excessUtilizationWad = DecimalMath.ratioWad(
            (utilizationWad - OPTIMAL_UTILIZATION), (1e18 - OPTIMAL_UTILIZATION), Math.Rounding.Trunc
        );

        uint256 postKinkContribution = Math.mulDiv(SLOPE2, excessUtilizationWad, 1e18, Math.Rounding.Trunc);

        return BASE_RATE + SLOPE1 + postKinkContribution;

        // if (utilizationWad == 0) {
        //     // U = 0%
        //     return BASE_RATE;
        // } else if (utilizationWad > 0 && utilizationWad < OPTIMAL_UTILIZATION) {
        //     // eg U = 40%
        //     return BASE_RATE + SLOPE1 * utilizationWad / OPTIMAL_UTILIZATION;
        // } else if (utilizationWad == OPTIMAL_UTILIZATION) {
        //     // U = 80%
        //     return BASE_RATE + SLOPE1;
        // } else if (utilizationWad > OPTIMAL_UTILIZATION && utilizationWad < 1e18) {
        //     // eg U = 90%
        //     utilizationWad = (utilizationWad - OPTIMAL_UTILIZATION) / (1e18 - OPTIMAL_UTILIZATION);
        //     return (BASE_RATE + SLOPE1) + SLOPE2 * utilizationWad;
        // } else {
        //     // U = 100%
        //     return BASE_RATE + SLOPE1 + SLOPE2;
        // }
    }

    function supplyRate(uint256 utilizationWad, uint256 borrowRateWad) public pure returns (uint256 netSupplyRate) {
        require(utilizationWad <= 1e18, InvalidUtilization(utilizationWad));

        if (utilizationWad == 0) return 0;

        // Mental steps:
        // 1. grossSupplyRate = borrowRate × utilization
        uint256 grossSupplyRate = Math.mulDiv(borrowRateWad, utilizationWad, 1e18, Math.Rounding.Trunc);

        // 2. supplierShare = 1 - reserveFactor
        uint256 supplierShare = 1e18 - RESERVE_FACTOR;

        // 3. netSupplyRate = grossSupplyRate × supplierShare
        return netSupplyRate = Math.mulDiv(grossSupplyRate, supplierShare, 1e18, Math.Rounding.Trunc);
    }
}
