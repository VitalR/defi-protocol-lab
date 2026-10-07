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
}
