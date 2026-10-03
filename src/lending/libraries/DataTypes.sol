// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";

library DataTypes {
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

    struct ReserveData {
        ReserveState state;
        address supplyToken;
        address debtToken;
        uint8 decimals;
        bool initialized;
    }
}
