// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { OracleDeviationGuard } from "src/labs/oracles/OracleDeviationGuard.sol";
import { PushOracleAdapter } from "src/labs/oracles/PushOracleAdapter.sol";
import { UniswapV3TwapOracleAdapter } from "src/labs/oracles/UniswapV3TwapOracleAdapter.sol";
import { MockUniswapV3Pool } from "test/mocks/MockUniswapV3Pool.sol";
import { MockAggregatorV3 } from "test/mocks/MockAggregatorV3.sol";
import { MockWETH } from "test/mocks/MockWETH.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";

contract OracleDeviationGuardIntegrationTest is Test {
    OracleDeviationGuard oracleGuard;
    PushOracleAdapter primaryOracle;
    UniswapV3TwapOracleAdapter referenceOracle;
    MockUniswapV3Pool pool;
    MockWETH mockETH;
    MockUSDC mockUSDC;

    uint256 maxDeviationBps;
    uint256 primaryOracleUpdatedAt;
    uint256 referenceOracleUpdatedAt;

    function setUp() public {
        skip(1 days);

        (primaryOracle,) = _setupPrimaryOracleWithETH(2000e18, 0, 1 hours);
        (referenceOracle,) = _setupReferenceOracleWithETH();

        maxDeviationBps = 1000; // 10%

        oracleGuard = new OracleDeviationGuard(primaryOracle, referenceOracle, maxDeviationBps);
    }

    function test_Deploy_Configuration() public {
        assertEq(address(oracleGuard.primaryOracle()), address(primaryOracle));
        assertEq(address(oracleGuard.referenceOracle()), address(referenceOracle));
        assertEq(bytes32(oracleGuard.baseIdentifier()), bytes32("ETH"));
        assertEq(bytes32(oracleGuard.quoteIdentifier()), bytes32("USD"));
        assertEq(oracleGuard.maxDeviationBps(), 1000);
    }

    function _setupPrimaryOracleWithETH(int256 amount, uint256 updatedAt, uint64 maxStaleness)
        private
        returns (PushOracleAdapter, uint256)
    {
        MockAggregatorV3 feedETH = new MockAggregatorV3(uint256(1), uint8(18), "MockAggregatorV3::ETH/USD");
        if (updatedAt == 0) {
            primaryOracleUpdatedAt = block.timestamp;
        } else {
            primaryOracleUpdatedAt = updatedAt;
        }

        feedETH.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1,
                answer: amount,
                startedAt: block.timestamp,
                updatedAt: primaryOracleUpdatedAt,
                answeredInRound: 1
            })
        );

        if (maxStaleness == 0) {
            maxStaleness = 1 hours;
        }

        primaryOracle = new PushOracleAdapter(address(feedETH), bytes32("ETH"), bytes32("USD"), maxStaleness);

        return (primaryOracle, primaryOracleUpdatedAt);
    }

    function _setupReferenceOracleWithETH() private returns (UniswapV3TwapOracleAdapter, uint256) {
        mockETH = new MockWETH();
        mockUSDC = new MockUSDC();
        pool = new MockUniswapV3Pool(address(mockUSDC), address(mockETH));
        referenceOracle = new UniswapV3TwapOracleAdapter(
            address(pool), address(mockETH), address(mockUSDC), bytes32("ETH"), bytes32("USD"), 1800, 3600
        );

        // 1 WETH ≈ 2,000 USDC
        // token0 = USDC
        // token1 = WETH

        // Praw​=​WETHraw/USDCraw​​=1.0001^tick

        // WETH/USDC=1/2000
        // Praw=(1/2000)×10^(18−6)=10^12/2000=500,000,000

        // => tick=ln(Praw​)/ln(1.0001)​
        // => tick=ln(500,000,000)/ln(1.0001)​≈200311

        // => meanTick = 200_311
        // => currentTickCumulative = meanTick × timePeriod = 200_311 × 1_800 = 360_559_800
        pool.setObserveResult(1800, 0, 360_559_800);
        referenceOracleUpdatedAt = block.timestamp - 30;
        pool.setLatestObservation(0, uint32(referenceOracleUpdatedAt), true);

        return (referenceOracle, referenceOracleUpdatedAt);
    }

    function test_LatestPrice_AcceptsConsistentPushAndTwapPrices() public {
        (uint256 priceWad, uint256 updatedAt) = oracleGuard.latestPrice();

        assertEq(priceWad, 2000e18);
        assertEq(updatedAt, referenceOracleUpdatedAt);
    }

    function test_LatestPrice_RevertsWhenTwapDeviationExceedsLimit() public {
        (UniswapV3TwapOracleAdapter referenceOracle1,) = _setupReferenceOracleWithETH3000();

        oracleGuard = new OracleDeviationGuard(primaryOracle, referenceOracle1, 1000);

        uint256 primaryPrice = 2000e18;
        uint256 referencePrice = 3_000_104_290_000_000_000_000;
        uint256 expectedDeviationBps = 3334;

        vm.expectRevert(
            abi.encodeWithSelector(
                OracleDeviationGuard.PriceDeviationExceeded.selector,
                primaryPrice,
                referencePrice,
                expectedDeviationBps,
                maxDeviationBps
            )
        );
        oracleGuard.latestPrice();
    }

    function _setupReferenceOracleWithETH3000() private returns (UniswapV3TwapOracleAdapter, uint256) {
        mockETH = new MockWETH();
        mockUSDC = new MockUSDC();
        pool = new MockUniswapV3Pool(address(mockUSDC), address(mockETH));
        referenceOracle = new UniswapV3TwapOracleAdapter(
            address(pool), address(mockETH), address(mockUSDC), bytes32("ETH"), bytes32("USD"), 1800, 3600
        );

        // 1 WETH ≈ 3,000 USDC
        // token0 = USDC
        // token1 = WETH
        // => meanTick = 196_256
        // => 196_256 × 1_800 = 353_260_800

        // Price 3000 USDC for 1 WETH:

        // Praw=10^12/3000=333,333,333.33

        // tick=ln(333,333,333.33)/ln(1.0001)≈196256

        // Universal formula:
        // tick=ln(10^12/WETHPriceInUSDC)/ln(1.0001)

        // delta tick cumulative = 353,260,800
        // mean tick             = 196,256
        // WETH price            ≈ 3,000 USDC

        // Tick 196_256 quotes approximately 3,000.10429 USDC/WETH,
        // so the integration assertion uses the actual adapter output.

        pool.setObserveResult(1800, 0, int56(196_256 * 1800));
        referenceOracleUpdatedAt = block.timestamp - 30;
        pool.setLatestObservation(0, uint32(referenceOracleUpdatedAt), true);

        return (referenceOracle, referenceOracleUpdatedAt);
    }

    function test_LatestPrice_ReturnsOldestSourceTimestamp() public {
        assertLt(referenceOracleUpdatedAt, primaryOracleUpdatedAt);

        (, uint256 updatedAt) = oracleGuard.latestPrice();

        assertEq(updatedAt, referenceOracleUpdatedAt);
    }

    // primary failure   → revert
    // reference failure → revert

    // NO FALLBACK
    // NO DEGRADED MODE
    // FAIL CLOSED

    // PushOracleAdapter revert
    //         ↓
    // OracleDeviationGuard
    //         ↓
    // same revert propagated
    function test_LatestPrice_PropagatesStalePushPrice() public {
        uint256 staleUpdatedAt = block.timestamp - 2 hours;
        uint256 maxStaleness = 1 hours;

        (PushOracleAdapter stalePrimary,) = _setupPrimaryOracleWithETH(2000e18, staleUpdatedAt, uint64(maxStaleness));
        (UniswapV3TwapOracleAdapter freshReference,) = _setupReferenceOracleWithETH();

        OracleDeviationGuard guard = new OracleDeviationGuard(stalePrimary, freshReference, maxDeviationBps);

        vm.expectRevert(
            abi.encodeWithSelector(PushOracleAdapter.StalePrice.selector, staleUpdatedAt, block.timestamp, maxStaleness)
        );
        guard.latestPrice();
    }

    // Mock pool
    // → TWAP observation validation
    // → UniswapV3TwapOracleAdapter revert
    // → OracleDeviationGuard propagates
    function test_LatestPrice_PropagatesStaleTwapObservation() public {
        uint256 staleUpdatedAt = block.timestamp - 2 hours;
        uint256 maxObservationStaleness = 1 hours;

        pool.setLatestObservation(0, uint32(staleUpdatedAt), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapOracleAdapter.StaleObservation.selector,
                staleUpdatedAt,
                block.timestamp,
                maxObservationStaleness
            )
        );

        oracleGuard.latestPrice();
    }
}
