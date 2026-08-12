// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { UniswapV3OracleMath } from "src/labs/oracles/libraries/UniswapV3OracleMath.sol";

contract UniswapV3OracleMathHarness {
    function arithmeticMeanTick(int56 tickCumulativeDelta, uint32 window) public pure returns (int24) {
        return UniswapV3OracleMath.arithmeticMeanTick(tickCumulativeDelta, window);
    }

    function getQuoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        public
        pure
        returns (uint256)
    {
        return UniswapV3OracleMath.getQuoteAtTick(tick, baseAmount, baseToken, quoteToken);
    }
}
