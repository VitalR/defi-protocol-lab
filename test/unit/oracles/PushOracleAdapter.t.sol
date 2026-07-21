// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { PushOracleAdapter } from "src/labs/oracles/PushOracleAdapter.sol";
import { MockAggregatorV3 } from "test/mocks/MockAggregatorV3.sol";

contract PushOracleAdapterTest is Test {
    PushOracleAdapter adapter;
    MockAggregatorV3 feed;

    function setUp() public {
        feed = new MockAggregatorV3(uint256(1), uint8(8));
        adapter = new PushOracleAdapter(address(feed), bytes32("ETH"), bytes32("USD"), 1 hours);
    }

    function test_Deployment_Reverts_InvalidConstructorConfiguration() public {
        vm.expectRevert(PushOracleAdapter.ZeroFeed.selector);
        new PushOracleAdapter(address(0), bytes32("ETH"), bytes32("USD"), 1 hours);

        vm.expectRevert(abi.encodeWithSelector(PushOracleAdapter.InvalidPair.selector, bytes32(0), bytes32("USD")));
        new PushOracleAdapter(address(feed), bytes32(0), bytes32("USD"), 1 hours);

        vm.expectRevert(abi.encodeWithSelector(PushOracleAdapter.InvalidPair.selector, bytes32("ETH"), bytes32(0)));
        new PushOracleAdapter(address(feed), bytes32("ETH"), bytes32(0), 1 hours);

        vm.expectRevert(abi.encodeWithSelector(PushOracleAdapter.InvalidPair.selector, bytes32("ETH"), bytes32("ETH")));
        new PushOracleAdapter(address(feed), bytes32("ETH"), bytes32("ETH"), 1 hours);

        vm.expectRevert(PushOracleAdapter.ZeroMaxStaleness.selector);
        new PushOracleAdapter(address(feed), bytes32("ETH"), bytes32("USD"), 0);

        MockAggregatorV3 feedWithUnsupportedDecimals = new MockAggregatorV3(uint256(1), uint8(21));
        vm.expectRevert(abi.encodeWithSelector(PushOracleAdapter.UnsupportedFeedDecimals.selector, uint8(21)));
        new PushOracleAdapter(address(feedWithUnsupportedDecimals), bytes32("ETH"), bytes32("USD"), 10);
    }

    function test_LatestRoundData_Eightdecimals_NormalizesCorrectly() public {
        uint256 expectedUpdatedAt = block.timestamp;

        feed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1, answer: 2000e8, startedAt: block.timestamp, updatedAt: expectedUpdatedAt, answeredInRound: 1
            })
        );

        (uint256 priceWad, uint256 updatedAt) = adapter.latestPrice();

        assertEq(priceWad, 2000e18);
        assertEq(updatedAt, expectedUpdatedAt);
    }

    function test_LatestRoundData_Eighteendecimals_NormalizesCorrectly() public {
        MockAggregatorV3 feed18decimal = new MockAggregatorV3(uint256(1), uint8(18));
        PushOracleAdapter adapter1 = new PushOracleAdapter(address(feed18decimal), bytes32("ETH"), bytes32("USD"), 3600);

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
    }

    function test_LatestRoundData_Reverts_InvalidRound() public {
        uint256 expectedUpdatedAt = block.timestamp;

        feed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 0, answer: 2000e8, startedAt: block.timestamp, updatedAt: expectedUpdatedAt, answeredInRound: 1
            })
        );

        vm.expectRevert(abi.encodeWithSelector(PushOracleAdapter.InvalidRound.selector, uint80(0)));
        adapter.latestPrice();
    }

    function test_LatestRoundData_Reverts_InvalidPrice() public {
        uint256 expectedUpdatedAt = block.timestamp;

        feed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1,
                answer: int256(0),
                startedAt: block.timestamp,
                updatedAt: expectedUpdatedAt,
                answeredInRound: 1
            })
        );

        vm.expectRevert(abi.encodeWithSelector(PushOracleAdapter.InvalidPrice.selector, int256(0)));
        adapter.latestPrice();
    }

    function test_LatestPrice_Reverts_WhenPriceIsNegative() public {
        int256 invalidAnswer = -1;

        feed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1,
                answer: invalidAnswer,
                startedAt: block.timestamp,
                updatedAt: block.timestamp,
                answeredInRound: 1
            })
        );

        vm.expectRevert(abi.encodeWithSelector(PushOracleAdapter.InvalidPrice.selector, invalidAnswer));
        adapter.latestPrice();
    }

    function test_LatestRoundData_Reverts_InvalidTimestamp() public {
        feed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1, answer: 2000e8, startedAt: block.timestamp, updatedAt: 0, answeredInRound: 1
            })
        );

        vm.expectRevert(abi.encodeWithSelector(PushOracleAdapter.InvalidTimestamp.selector, uint256(0)));
        adapter.latestPrice();
    }

    function test_LatestRoundData_Reverts_IncompleteRound() public {
        uint256 expectedUpdatedAt = block.timestamp;

        feed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1, answer: 2000e8, startedAt: block.timestamp, updatedAt: expectedUpdatedAt, answeredInRound: 0
            })
        );

        vm.expectRevert(abi.encodeWithSelector(PushOracleAdapter.IncompleteRound.selector, uint80(1), uint80(0)));
        adapter.latestPrice();
    }

    function test_LatestRoundData_Reverts_FutureTimestamp() public {
        vm.warp(10_000);
        uint256 expectedUpdatedAt = block.timestamp + 1000;

        feed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1, answer: 2000e8, startedAt: block.timestamp, updatedAt: expectedUpdatedAt, answeredInRound: 1
            })
        );

        vm.expectRevert(
            abi.encodeWithSelector(PushOracleAdapter.FutureTimestamp.selector, expectedUpdatedAt, block.timestamp)
        );
        adapter.latestPrice();
    }

    function test_LatestPrice_Reverts_WhenPriceExceedsMaxStaleness() public {
        vm.warp(10_000);

        uint256 expectedUpdatedAt = block.timestamp - 1 hours - 1;

        feed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1,
                answer: 2000e8,
                startedAt: expectedUpdatedAt,
                updatedAt: expectedUpdatedAt,
                answeredInRound: 1
            })
        );

        vm.expectRevert(
            abi.encodeWithSelector(PushOracleAdapter.StalePrice.selector, expectedUpdatedAt, block.timestamp, 1 hours)
        );
        adapter.latestPrice();
    }

    function test_LatestPrice_Succeeds_AtMaxStalenessBoundary() public {
        vm.warp(10_000);

        uint256 expectedUpdatedAt = block.timestamp - 1 hours;

        feed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1,
                answer: 2000e8,
                startedAt: expectedUpdatedAt,
                updatedAt: expectedUpdatedAt,
                answeredInRound: 1
            })
        );
        adapter.latestPrice();
    }
}

// Eight-decimal price normalizes correctly:
// 2000e8 → 2000e18
// Eighteen-decimal price remains unchanged.
// Returned updatedAt matches the feed.
// Zero answer reverts.
// Negative answer reverts.
// Zero updatedAt reverts.
// Zero roundId reverts.
// answeredInRound < roundId reverts.
// Future timestamp reverts.
// Price exactly maxStaleness old succeeds.
// Price maxStaleness + 1 old reverts.
// Feed decimals above 18 are rejected.
// Invalid constructor configuration is rejected.
