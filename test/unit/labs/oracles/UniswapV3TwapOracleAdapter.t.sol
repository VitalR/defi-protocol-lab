// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { UniswapV3TwapOracleAdapter } from "src/labs/oracles/UniswapV3TwapOracleAdapter.sol";
import { UniswapV3OracleMath } from "src/labs/oracles/libraries/UniswapV3OracleMath.sol";
import { MockUniswapV3Pool } from "test/mocks/MockUniswapV3Pool.sol";
import { MockERC20Decimals } from "test/mocks/MockERC20Decimals.sol";
import { MockWETH } from "test/mocks/MockWETH.sol";
import { MockWBTC } from "test/mocks/MockWBTC.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";

contract UniswapV3TwapOracleAdapterTest is Test {
    UniswapV3TwapOracleAdapter adapter;
    MockUniswapV3Pool pool;
    MockWETH mockETH;
    MockUSDC mockUSDC;

    function setUp() public {
        mockETH = new MockWETH();
        mockUSDC = new MockUSDC();
        pool = new MockUniswapV3Pool(address(mockUSDC), address(mockETH));
        adapter = new UniswapV3TwapOracleAdapter(
            address(pool), address(mockETH), address(mockUSDC), bytes32("ETH"), bytes32("USDC"), 1800, 3600
        );
    }

    function test_Deployment_ConstructorConfiguration() public {
        assertEq(address(adapter.pool()), address(pool));
        assertEq(address(adapter.baseToken()), address(mockETH));
        assertEq(address(adapter.quoteToken()), address(mockUSDC));
        assertEq(uint8(adapter.baseTokenDecimals()), uint8(18));
        assertEq(uint8(adapter.quoteTokenDecimals()), uint8(6));
        assertEq(bytes32(adapter.baseIdentifier()), bytes32("ETH"));
        assertEq(bytes32(adapter.quoteIdentifier()), bytes32("USDC"));
        assertEq(uint32(adapter.twapWindow()), uint32(1800));
        assertEq(uint32(adapter.maxObservationStaleness()), uint32(3600));
    }

    function test_Deployment_Reverts_ConstructorConfiguration() public {
        vm.expectRevert(UniswapV3TwapOracleAdapter.ZeroPool.selector);
        new UniswapV3TwapOracleAdapter(
            address(0), address(mockETH), address(mockUSDC), bytes32("ETH"), bytes32("USDC"), 1800, 3600
        );
        vm.expectRevert(UniswapV3TwapOracleAdapter.ZeroBaseToken.selector);
        new UniswapV3TwapOracleAdapter(
            address(pool), address(0), address(mockUSDC), bytes32("ETH"), bytes32("USDC"), 1800, 3600
        );
        vm.expectRevert(UniswapV3TwapOracleAdapter.ZeroQuoteToken.selector);
        new UniswapV3TwapOracleAdapter(
            address(pool), address(mockETH), address(0), bytes32("ETH"), bytes32("USDC"), 1800, 3600
        );
        vm.expectRevert(UniswapV3TwapOracleAdapter.SameToken.selector);
        new UniswapV3TwapOracleAdapter(
            address(pool), address(mockETH), address(mockETH), bytes32("ETH"), bytes32("USDC"), 1800, 3600
        );
        vm.expectRevert(UniswapV3TwapOracleAdapter.ZeroTwapWindow.selector);
        new UniswapV3TwapOracleAdapter(
            address(pool), address(mockETH), address(mockUSDC), bytes32("ETH"), bytes32("USDC"), 0, 3600
        );
        vm.expectRevert(UniswapV3TwapOracleAdapter.ZeroMaxObservationStaleness.selector);
        new UniswapV3TwapOracleAdapter(
            address(pool), address(mockETH), address(mockUSDC), bytes32("ETH"), bytes32("USDC"), 1800, 0
        );

        vm.expectRevert(
            abi.encodeWithSelector(UniswapV3TwapOracleAdapter.InvalidPair.selector, bytes32(0), bytes32("USDC"))
        );
        new UniswapV3TwapOracleAdapter(
            address(pool), address(mockETH), address(mockUSDC), bytes32(0), bytes32("USDC"), 1800, 3600
        );
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV3TwapOracleAdapter.InvalidPair.selector, bytes32("ETH"), bytes32(0))
        );
        new UniswapV3TwapOracleAdapter(
            address(pool), address(mockETH), address(mockUSDC), bytes32("ETH"), bytes32(0), 1800, 3600
        );
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV3TwapOracleAdapter.InvalidPair.selector, bytes32("ETH"), bytes32("ETH"))
        );
        new UniswapV3TwapOracleAdapter(
            address(pool), address(mockETH), address(mockUSDC), bytes32("ETH"), bytes32("ETH"), 1800, 3600
        );
    }

    function test_Deployment_Reverts_PoolTokenMismatch() public {
        MockWBTC mockWBTC = new MockWBTC();

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapOracleAdapter.PoolTokenMismatch.selector,
                address(mockUSDC),
                address(mockETH),
                address(mockWBTC),
                address(mockUSDC)
            )
        );

        new UniswapV3TwapOracleAdapter(
            address(pool), address(mockWBTC), address(mockUSDC), bytes32("WBTC"), bytes32("USDC"), 1800, 3600
        );
    }

    function test_Deployment_Reverts_UnsupportedBaseTokenDecimals() public {
        MockERC20Decimals excessToken = new MockERC20Decimals("Excess", "EXC", 19);

        MockUniswapV3Pool excessPool = new MockUniswapV3Pool(address(mockUSDC), address(excessToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapOracleAdapter.UnsupportedTokenDecimals.selector,
                address(excessToken),
                excessToken.decimals()
            )
        );

        new UniswapV3TwapOracleAdapter(
            address(excessPool), address(excessToken), address(mockUSDC), bytes32("EXCESS"), bytes32("USDC"), 1800, 3600
        );
    }

    function test_Deployment_Reverts_UnsupportedQuoteTokenDecimals() public {
        MockERC20Decimals excessToken = new MockERC20Decimals("Excess", "EXC", 19);

        MockUniswapV3Pool excessPool = new MockUniswapV3Pool(address(mockETH), address(excessToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapOracleAdapter.UnsupportedTokenDecimals.selector,
                address(excessToken),
                excessToken.decimals()
            )
        );

        new UniswapV3TwapOracleAdapter(
            address(excessPool), address(mockETH), address(excessToken), bytes32("ETH"), bytes32("EXCESS"), 1800, 3600
        );
    }

    function test_LatestPrice_NormalizesSixDecimalQuoteToWad() public {
        skip(1 days);

        pool.setObserveResult(
            1800, // adapter should ask window 1800 sec
            100_000, // accumulator 1800 sec ago
            103_600 // accumulator now
        );
        // adapter will get:
        // delta = 103,600 − 100,000 = 3,600
        // meanTick = 3,600 / 1,800 = 2

        pool.setLatestObservation(
            0, // latest observation index = 0
            uint32(block.timestamp - 30), // observation record 30 sec ago
            true // observation initialized
        );

        // token0 = USDC (6 decimals)
        // token1 = WETH (18 decimals)

        // Uniswap raw-price:
        // Praw = WETHraw / USDCraw = 1.0001 ** tick ≈ 1.0002

        // Adapter: WETH → USDC:
        // baseAmount = 1e18 WETH raw units

        // quoteAmount =
        //     1e18 / 1.0002
        //     ≈ 999800029996000499 USDC raw units

        // 999800029996.000499 USDC ≈ 999.8 billion USDC per WETH

        // 6 → 18 decimals:
        // 999800029996000499 × 1e12 = 999800029996000499000000000000

        (uint256 priceWad,) = adapter.latestPrice();

        assertEq(priceWad, 999_800_029_996_000_499_000_000_000_000);
    }

    function test_LatestPrice_ReturnsWethPriceInUsdcWad() public {
        skip(1 days);

        // 1 WETH ≈ 2,000 USDC
        // token0 = USDC
        // token1 = WETH
        // => meanTick = 200_311

        // 200_311 × 1_800 = 360_559_800
        pool.setObserveResult(1800, 0, 360_559_800);

        uint256 expectedUpdatedAt = block.timestamp - 30;

        pool.setLatestObservation(0, uint32(expectedUpdatedAt), true);

        (uint256 priceWad, uint256 updatedAt) = adapter.latestPrice();

        assertApproxEqRel(
            priceWad,
            2000e18,
            1e14 // 0.01%
        );
        assertEq(updatedAt, expectedUpdatedAt);
    }

    function test_LatestPrice_AcceptsObservationAtStalenessLimit() public {
        skip(1 days);

        pool.setObserveResult(1800, 0, 360_559_800);

        uint256 expectedUpdatedAt = block.timestamp - 3600;

        pool.setLatestObservation(0, uint32(expectedUpdatedAt), true);

        (, uint256 updatedAt) = adapter.latestPrice();

        assertEq(updatedAt, expectedUpdatedAt);
    }

    function test_LatestPrice_Reverts_UninitializedObservation() public {
        pool.setObserveResult(1800, 0, 360_559_800);
        pool.setLatestObservation(0, uint32(block.timestamp), false);

        vm.expectRevert(abi.encodeWithSelector(UniswapV3TwapOracleAdapter.UninitializedObservation.selector, 0));
        adapter.latestPrice();
    }

    function test_LatestPrice_Reverts_StaleObservation() public {
        skip(1 days);
        pool.setObserveResult(1800, 0, 360_559_800);
        uint256 expectedUpdatedAt = block.timestamp - 3601;
        pool.setLatestObservation(0, uint32(expectedUpdatedAt), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapOracleAdapter.StaleObservation.selector, expectedUpdatedAt, block.timestamp, 3600
            )
        );
        adapter.latestPrice();
    }

    function test_LatestPrice_Reverts_ObserveResultNotConfigured() public {
        pool.setLatestObservation(0, uint32(block.timestamp), true);

        vm.expectRevert(MockUniswapV3Pool.ObserveResultNotConfigured.selector);
        adapter.latestPrice();
    }

    function test_LatestPrice_Reverts_InvalidPrice() public {
        int24 zeroQuoteTick =
            uint160(address(mockETH)) < uint160(address(mockUSDC)) ? TickMath.MIN_TICK : TickMath.MAX_TICK;

        int56 cumulativeDelta = int56(zeroQuoteTick) * int56(uint56(1800));

        pool.setObserveResult(1800, 0, cumulativeDelta);
        pool.setLatestObservation(0, uint32(block.timestamp), true);

        vm.expectRevert(UniswapV3TwapOracleAdapter.InvalidPrice.selector);

        adapter.latestPrice();
    }

    function test_LatestPrice_Reverts_MeanTickAboveMaximum() public {
        int56 invalidMeanTick = int56(TickMath.MAX_TICK) + 1;

        int56 cumulativeDelta = invalidMeanTick * int56(uint56(1800));

        pool.setObserveResult(1800, 0, cumulativeDelta);
        pool.setLatestObservation(0, uint32(block.timestamp), true);

        vm.expectRevert(abi.encodeWithSelector(UniswapV3OracleMath.InvalidMeanTick.selector, invalidMeanTick));

        adapter.latestPrice();
    }

    function test_LatestPrice_Reverts_MeanTickBelowMinimum() public {
        int56 invalidMeanTick = int56(TickMath.MIN_TICK) - 1;

        int56 cumulativeDelta = invalidMeanTick * int56(uint56(1800));

        pool.setObserveResult(1800, 0, cumulativeDelta);
        pool.setLatestObservation(0, uint32(block.timestamp), true);

        vm.expectRevert(abi.encodeWithSelector(UniswapV3OracleMath.InvalidMeanTick.selector, invalidMeanTick));

        adapter.latestPrice();
    }

    function test_LatestPrice_HandlesUint32TimestampWraparound() public {
        vm.warp(uint256(type(uint32).max) + 100);

        pool.setObserveResult(1800, 0, 360_559_800);

        uint256 expectedUpdatedAt = block.timestamp - 30;

        pool.setLatestObservation(0, uint32(expectedUpdatedAt), true);

        (, uint256 updatedAt) = adapter.latestPrice();

        assertEq(updatedAt, expectedUpdatedAt);
    }

    function test_Deployment_AcceptsDirectPoolTokenOrder() public {
        UniswapV3TwapOracleAdapter directAdapter = new UniswapV3TwapOracleAdapter(
            address(pool),
            address(mockUSDC), // pool.token0
            address(mockETH), // pool.token1
            bytes32("USDC"),
            bytes32("ETH"),
            1800,
            3600
        );

        assertEq(address(directAdapter.baseToken()), address(mockUSDC));
        assertEq(address(directAdapter.quoteToken()), address(mockETH));
        assertEq(directAdapter.baseTokenDecimals(), 6);
        assertEq(directAdapter.quoteTokenDecimals(), 18);
    }

    function test_Deployment_Reverts_PartialDirectPairMatch() public {
        MockWBTC mockWBTC = new MockWBTC();

        // pool:
        // token0 = USDC
        // token1 = WETH
        //
        // requested:
        // base  = USDC  → first directPair condition is true
        // quote = WBTC  → second directPair condition is false

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3TwapOracleAdapter.PoolTokenMismatch.selector,
                address(mockUSDC),
                address(mockETH),
                address(mockUSDC),
                address(mockWBTC)
            )
        );

        new UniswapV3TwapOracleAdapter(
            address(pool), address(mockUSDC), address(mockWBTC), bytes32("USDC"), bytes32("WBTC"), 1800, 3600
        );
    }
}
