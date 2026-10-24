// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

library DataTypes {
    struct ReserveData {
        ReserveState state;
        ReserveConfiguration configuration;
        address supplyToken;
        address debtToken;
        uint8 decimals;
        bool initialized;
    }

    struct ReserveState {
        uint256 borrowIndex;
        uint256 liquidityIndex;
        uint256 availableLiquidity;
        uint256 accruedToTreasuryScaled;
        uint256 currentBorrowRate;
        uint256 currentLiquidityRate;
        uint256 reserveFactor;
        uint256 lastUpdateTimestamp;
    }

    struct ReserveConfiguration {
        uint256 ltvWad;
        uint256 liquidationThresholdWad;
        uint256 liquidationBonusWad;

        // Underlying token units. Zero means unlimited.
        uint256 supplyCap;
        uint256 borrowCap;

        bool borrowingEnabled;
        bool frozen;
        bool paused;
    }

    struct AccountData {
        uint256 collateralValueWad;
        uint256 debtValueWad;
        uint256 borrowCapacityWad;
        uint256 liquidationCapacityWad;
        uint256 availableBorrowsWad;
        uint256 healthFactorWad;
    }

    struct LiquidationLocalVars {
        uint256 userScaledDebt;
        uint256 userDebt;
        uint256 userScaledCollateral;
        uint256 userCollateral;
        uint256 healthFactorWad;
        uint256 closeFactorWad;
        uint256 debtBudget;
        uint256 scaledDebtAmount;
        uint256 scaledCollateralAmount;
    }
}
