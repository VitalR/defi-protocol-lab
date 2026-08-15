// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IUniswapV3PoolOracle } from "src/labs/oracles/interfaces/IUniswapV3PoolOracle.sol";

contract MockUniswapV3Pool is IUniswapV3PoolOracle {
    error UnexpectedSecondsAgosLength(uint256 actual);
    error UnexpectedSecondsAgo(uint256 index, uint32 actual, uint32 expected);
    error UnexpectedObservationIndex(uint256 actual, uint16 expected);
    error ObserveResultNotConfigured();

    address public immutable override token0;
    address public immutable override token1;

    uint32 private expectedWindow;

    int56 private pastTickCumulative;
    int56 private currentTickCumulative;

    uint16 private latestObservationIndex;
    uint32 private latestObservationTimestamp;
    bool private latestObservationInitialized;
    bool private observeResultConfigured;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setObserveResult(uint32 expectedWindow_, int56 pastTickCumulative_, int56 currentTickCumulative_)
        external
    {
        expectedWindow = expectedWindow_;
        pastTickCumulative = pastTickCumulative_;
        currentTickCumulative = currentTickCumulative_;
        observeResultConfigured = true;
    }

    function setLatestObservation(uint16 index_, uint32 timestamp_, bool initialized_) external {
        latestObservationIndex = index_;
        latestObservationTimestamp = timestamp_;
        latestObservationInitialized = initialized_;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        override
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(observeResultConfigured, ObserveResultNotConfigured());

        if (secondsAgos.length != 2) {
            revert UnexpectedSecondsAgosLength(secondsAgos.length);
        }

        if (secondsAgos[0] != expectedWindow) {
            revert UnexpectedSecondsAgo(0, secondsAgos[0], expectedWindow);
        }

        if (secondsAgos[1] != 0) {
            revert UnexpectedSecondsAgo(1, secondsAgos[1], 0);
        }

        tickCumulatives = new int56[](2);
        tickCumulatives[0] = pastTickCumulative;
        tickCumulatives[1] = currentTickCumulative;

        // Adapter does not use this accumulator,
        // but interface require to return it as an array.
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
    }

    function slot0()
        external
        view
        override
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        // Adapter use only observationIndex.
        sqrtPriceX96 = 0;
        tick = 0;
        observationIndex = latestObservationIndex;

        // Suppose there is only one existing observation slot in mock.
        observationCardinality = 1;
        observationCardinalityNext = 1;

        feeProtocol = 0;
        unlocked = true;
    }

    function observations(uint256 index)
        external
        view
        override
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        if (index != latestObservationIndex) {
            revert UnexpectedObservationIndex(index, latestObservationIndex);
        }

        blockTimestamp = latestObservationTimestamp;
        tickCumulative = currentTickCumulative;
        secondsPerLiquidityCumulativeX128 = 0;
        initialized = latestObservationInitialized;
    }
}
