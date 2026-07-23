// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { CollateralValueOracle } from "src/labs/oracles/CollateralValueOracle.sol";
import { OracleValuation } from "src/labs/oracles/OracleValuation.sol";
import { MockAggregatorV3 } from "test/mocks/MockAggregatorV3.sol";
import { PushOracleAdapter, IPriceOracle } from "src/labs/oracles/PushOracleAdapter.sol";

contract CollateralValueOracleTest is Test {
    CollateralValueOracle consumer;
    PushOracleAdapter adapter;
    MockAggregatorV3 feed;

    function setUp() public {
        feed = new MockAggregatorV3(uint256(1), uint8(8));
        adapter = new PushOracleAdapter(address(feed), bytes32("ETH"), bytes32("USD"), 1 hours);
        consumer = new CollateralValueOracle(adapter, 18);
    }

    function test_Deployment_Reverts_InvalidConstructorConfiguration() public {
        vm.expectRevert(CollateralValueOracle.ZeroOracle.selector);
        new CollateralValueOracle(IPriceOracle(address(0)), 18);

        vm.expectRevert(abi.encodeWithSelector(CollateralValueOracle.UnsupportedTokenDecimals.selector, uint8(19)));
        new CollateralValueOracle(IPriceOracle(adapter), 19);
    }

    function test_CollateralValue_ZeroAmount() public {
        uint256 expectedUpdatedAt = block.timestamp;
        feed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1, answer: 2000e8, startedAt: block.timestamp, updatedAt: expectedUpdatedAt, answeredInRound: 1
            })
        );

        (uint256 valueWad, uint256 updatedAt) = consumer.collateralValue(0);
        assertEq(valueWad, 0);
        assertEq(updatedAt, expectedUpdatedAt);
    }

    function test_CollateralValue_18decimal() public {
        MockAggregatorV3 feed18decimal = new MockAggregatorV3(uint256(1), uint8(18));
        PushOracleAdapter adapter1 = new PushOracleAdapter(address(feed18decimal), bytes32("ETH"), bytes32("USD"), 3600);
        CollateralValueOracle consumer1 = new CollateralValueOracle(adapter1, 18);

        uint256 expectedUpdatedAt = block.timestamp;

        feed18decimal.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1,
                answer: 2000e18,
                startedAt: block.timestamp,
                updatedAt: expectedUpdatedAt,
                answeredInRound: 1
            })
        );

        (uint256 priceWad, uint256 updatedAt) = adapter1.latestPrice();

        assertEq(priceWad, 2000e18);
        assertEq(updatedAt, expectedUpdatedAt);

        (uint256 valueWad, uint256 priceUpdatedAt) = consumer1.collateralValue(7e18);

        assertEq(valueWad, 14_000e18);
        assertEq(updatedAt, priceUpdatedAt);
    }

    function test_CollateralValue_6decimal() public {
        MockAggregatorV3 feed8decimal = new MockAggregatorV3(uint256(1), uint8(8));
        PushOracleAdapter adapter1 = new PushOracleAdapter(address(feed8decimal), bytes32("ETH"), bytes32("USD"), 3600);
        CollateralValueOracle consumer1 = new CollateralValueOracle(adapter1, 6);

        uint256 expectedUpdatedAt = block.timestamp;

        feed8decimal.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1, answer: 2000e8, startedAt: block.timestamp, updatedAt: expectedUpdatedAt, answeredInRound: 1
            })
        );

        (uint256 priceWad, uint256 updatedAt) = adapter1.latestPrice();

        assertEq(priceWad, 2000e18);
        assertEq(updatedAt, expectedUpdatedAt);

        (uint256 valueWad, uint256 priceUpdatedAt) = consumer1.collateralValue(5e6);

        assertEq(valueWad, 10_000e18);
        assertEq(updatedAt, priceUpdatedAt);
    }

    function test_Valuation_EnforcesConservativeRounding() public {
        MockAggregatorV3 roundingFeed = new MockAggregatorV3(1, 18);

        PushOracleAdapter roundingAdapter =
            new PushOracleAdapter(address(roundingFeed), bytes32("TOKEN"), bytes32("USD"), 1 hours);

        CollateralValueOracle roundingConsumer = new CollateralValueOracle(roundingAdapter, 18);

        roundingFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1,
                answer: int256(1e18 + 1),
                startedAt: block.timestamp,
                updatedAt: block.timestamp,
                answeredInRound: 1
            })
        );

        (uint256 collateralValue,) = roundingConsumer.collateralValue(1);

        (uint256 debtValue,) = roundingConsumer.debtValue(1);

        assertEq(collateralValue, 1);
        assertEq(debtValue, 2);
    }
}
