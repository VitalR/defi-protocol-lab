// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

library UniswapV3OracleMath {
    error InvalidMeanTick(int56 meanTick56);

    // Suppose:
    // tick cumulative 30 minutes ago = 1,000,000
    // tick cumulative now            = 1,003,601
    // delta                          = 3,601
    // window                         = 1,800

    // Then:
    // mean tick = floor(3601 / 1800) = 2

    // For a negative result:
    // delta  = -3601
    // window = 1800

    // exact result              = -2.00055...
    // Solidity division result  = -2
    // mathematical floor        = -3

    function arithmeticMeanTick(int56 tickCumulativeDelta, uint32 window) internal pure returns (int24 meanTick) {
        int56 divisor = int56(uint56(window));
        int56 meanTick56 = tickCumulativeDelta / divisor;

        if (tickCumulativeDelta < 0 && tickCumulativeDelta % divisor != 0) {
            meanTick56--;
        }

        if (meanTick56 < int56(TickMath.MIN_TICK) || meanTick56 > int56(TickMath.MAX_TICK)) {
            revert InvalidMeanTick(meanTick56);
        }

        meanTick = int24(meanTick56);
    }

    function getQuoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);

        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);

            quoteAmount = baseToken < quoteToken
                ? Math.mulDiv(ratioX192, baseAmount, 1 << 192)
                : Math.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 64);

            quoteAmount = baseToken < quoteToken
                ? Math.mulDiv(ratioX128, baseAmount, 1 << 128)
                : Math.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
