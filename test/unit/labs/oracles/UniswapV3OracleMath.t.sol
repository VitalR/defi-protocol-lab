// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { UniswapV3OracleMath } from "src/labs/oracles/libraries/UniswapV3OracleMath.sol";
import { UniswapV3OracleMathHarness } from "test/helpers/UniswapV3OracleMathHarness.sol";
import { MockWETH } from "test/mocks/MockWETH.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";

contract UniswapV3OracleMathTest is Test {
    UniswapV3OracleMathHarness harness;
    MockWETH mockETH;
    MockUSDC mockUSDC;

    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);

    uint128 internal constant ONE_TOKEN = 1e18;

    function setUp() public {
        harness = new UniswapV3OracleMathHarness();
        mockETH = new MockWETH();
        mockUSDC = new MockUSDC();
    }

    function test_ArithmeticMeanTick_ReturnsExactPositiveResult() public {
        int24 meanTick = harness.arithmeticMeanTick(3600, 1800);
        assertEq(meanTick, 2);
    }

    function test_ArithmeticMeanTick_ReturnsExactNegativeResult() public {
        int24 meanTick = harness.arithmeticMeanTick(-3600, 1800);
        assertEq(meanTick, -2);
    }

    function test_ArithmeticMeanTick_RoundsPositiveTowardNegativeInfinity() public {
        int24 meanTick = harness.arithmeticMeanTick(3601, 1800);
        // 3601 / 1800 = 2.0005...
        assertEq(meanTick, 2);
    }

    function test_ArithmeticMeanTick_RoundsNegativeInexactTowardNegativeInfinity() public {
        int24 meanTick = harness.arithmeticMeanTick(-3601, 1800);
        // Mathematical floor(-2.0005...) = -3.
        // Solidity itself would truncate to -2.
        assertEq(meanTick, -3);
    }

    function test_ArithmeticMeanTick_Reverts_BelowMinimum() public {
        int56 belowMinimum = int56(TickMath.MIN_TICK) - 1;
        vm.expectRevert(abi.encodeWithSelector(UniswapV3OracleMath.InvalidMeanTick.selector, belowMinimum));
        harness.arithmeticMeanTick(belowMinimum, 1);
    }

    function test_ArithmeticMeanTick_Reverts_AboveMaximum() public {
        int56 aboveMaximum = int56(TickMath.MAX_TICK) + 1;
        vm.expectRevert(abi.encodeWithSelector(UniswapV3OracleMath.InvalidMeanTick.selector, aboveMaximum));
        harness.arithmeticMeanTick(aboveMaximum, 1);
    }

    function test_GetQuoteAtTick_AtZeroTick_ReturnsOneToOne() public {
        uint256 directQuote = harness.getQuoteAtTick(0, ONE_TOKEN, TOKEN0, TOKEN1);
        uint256 inverseQuote = harness.getQuoteAtTick(0, ONE_TOKEN, TOKEN1, TOKEN0);

        // tick 0:
        // token1/token0 = 1.0001^0 = 1
        assertEq(directQuote, ONE_TOKEN);
        assertEq(inverseQuote, ONE_TOKEN);
    }

    function test_GetQuoteAtTick_PositiveTick_QuotesBothDirections() public {
        // 1.0001^6931 ≈ 2
        int24 tick = 6931;

        // TOKEN0 < TOKEN1
        uint256 directQuote = harness.getQuoteAtTick(tick, ONE_TOKEN, TOKEN0, TOKEN1);

        // P = TOKEN1 / TOKEN0 = 1.0001^tick;
        // tick = 6931:
        // 1.0001^6931 ≈ 1.9998 ≈ 2
        // => TOKEN1 / TOKEN0 ≈ 2
        // => Practically: 1 TOKEN0 = 2 TOKEN1

        // quote=1e18×1.9998≈2e18
        assertApproxEqRel(directQuote, 2e18, 1e14);

        // Inverse
        uint256 inverseQuote = harness.getQuoteAtTick(tick, ONE_TOKEN, TOKEN1, TOKEN0);

        // If 1 TOKEN0 ≈ 2 TOKEN1 => 1 TOKEN1 ≈ 1/2 TOKEN0
        // quote=1e18/1.9998≈0.50005e18
        assertApproxEqRel(
            inverseQuote,
            0.5e18, // the same as 5e17
            1e14 // possible rel 0.01%
        );
    }

    function test_GetQuoteAtTick_HighSqrtPrice_QuotesBothDirections() public {
        int24 tick = 500_000;

        // positive very-high tick
        // → token1/token0 >> 1

        // TOKEN0 → TOKEN1
        // → quote must be much larger

        // TOKEN1 → TOKEN0
        // → quote must be much smaller

        // sqrtPriceX96 > type(uint128).max

        uint256 directQuote = harness.getQuoteAtTick(tick, ONE_TOKEN, TOKEN0, TOKEN1);

        uint256 inverseQuote = harness.getQuoteAtTick(tick, ONE_TOKEN, TOKEN1, TOKEN0);

        assertGt(directQuote, ONE_TOKEN);
        assertGe(inverseQuote, 0);
        assertLt(inverseQuote, ONE_TOKEN);
    }
}
