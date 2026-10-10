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
        uint256 accruedToTreasury;
        uint256 currentBorrowRate;
        uint256 currentLiquidityRate;
        uint256 reserveFactor;
        uint256 lastUpdateTimestamp;
    }

    struct ReserveConfiguration {
        uint256 ltvWad;
        uint256 liquidationThresholdWad;
        bool borrowingEnabled;
    }

    struct AccountData {
        uint256 collateralValueWad;
        uint256 debtValueWad;
        uint256 borrowCapacityWad;
        uint256 liquidationCapacityWad;
        uint256 availableBorrowsWad;
        uint256 healthFactorWad;
    }
}
