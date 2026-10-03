// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { OracleDeviationGuard, Math } from "src/labs/oracles/OracleDeviationGuard.sol";
import { PushOracleAdapter, IPriceOracle } from "src/labs/oracles/PushOracleAdapter.sol";
import { MockAggregatorV3 } from "test/mocks/MockAggregatorV3.sol";
import { MockPriceOracle } from "test/mocks/MockPriceOracle.sol";
import { MockWETH } from "test/mocks/MockWETH.sol";
import { MockWBTC } from "test/mocks/MockWBTC.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";

contract OracleDeviationGuardTest is Test {
    OracleDeviationGuard oracleGuard;
    PushOracleAdapter primaryOracle;
    PushOracleAdapter referenceOracle;
    MockWETH mockETH;
    MockWBTC mockWBTC;
    MockUSDC mockUSDC;

    function setUp() public {
        (primaryOracle,) = _setupPrimaryOracleWithETH(2000e18, 0);
        (referenceOracle,) = _setupReferenceOracleWithETH(2000e18, 0);

        oracleGuard = new OracleDeviationGuard(primaryOracle, referenceOracle, 2000);
    }

    function test_Deploy_Configuration() public {
        assertEq(address(oracleGuard.primaryOracle()), address(primaryOracle));
        assertEq(address(oracleGuard.referenceOracle()), address(referenceOracle));
        assertEq(oracleGuard.maxDeviationBps(), 2000);
        assertEq(bytes32(oracleGuard.baseIdentifier()), bytes32("ETH"));
        assertEq(bytes32(oracleGuard.quoteIdentifier()), bytes32("USD"));
    }

    function test_Deploy_Reverts() public {
        vm.expectRevert(OracleDeviationGuard.ZeroPrimaryOracle.selector);
        new OracleDeviationGuard(IPriceOracle(address(0)), referenceOracle, 2000);

        vm.expectRevert(OracleDeviationGuard.ZeroReferenceOracle.selector);
        new OracleDeviationGuard(primaryOracle, IPriceOracle(address(0)), 2000);

        vm.expectRevert(OracleDeviationGuard.SameOracle.selector);
        new OracleDeviationGuard(primaryOracle, primaryOracle, 2000);

        vm.expectRevert(OracleDeviationGuard.SameOracle.selector);
        new OracleDeviationGuard(referenceOracle, referenceOracle, 2000);

        vm.expectRevert(abi.encodeWithSelector(OracleDeviationGuard.InvalidMaxDeviationBps.selector, 0));
        new OracleDeviationGuard(primaryOracle, referenceOracle, 0);

        vm.expectRevert(abi.encodeWithSelector(OracleDeviationGuard.InvalidMaxDeviationBps.selector, 5100));
        new OracleDeviationGuard(primaryOracle, referenceOracle, 5100);
    }

    function test_Deploy_Reverts_OracleMismatch() public {
        (PushOracleAdapter primaryOracle1,) = _setupPrimaryOracleWithWBTC();
        (PushOracleAdapter referenceOracle1,) = _setupReferenceOracleWithUSDC2ETH();

        vm.expectRevert(
            abi.encodeWithSelector(OracleDeviationGuard.OracleBaseMismatch.selector, bytes32("WBTC"), bytes32("ETH"))
        );
        new OracleDeviationGuard(primaryOracle1, referenceOracle, 2000);

        (PushOracleAdapter primaryOracle2,) = _setupPrimaryOracleWithWBTC();
        (PushOracleAdapter referenceOracle2,) = _setupReferenceOracleWithWBTC2ETH();

        vm.expectRevert(
            abi.encodeWithSelector(OracleDeviationGuard.OracleQuoteMismatch.selector, bytes32("USD"), bytes32("ETH"))
        );
        new OracleDeviationGuard(primaryOracle2, referenceOracle2, 2000);
    }

    function test_LatestPrice_EqualPricesProduceZeroDeviation() public {
        (uint256 priceWad, uint256 updatedAt) = oracleGuard.latestPrice();

        assertEq(priceWad, 2000e18);
        assertEq(updatedAt, block.timestamp);
    }

    function test_LatestPrice_DeviationExactlyLimitSucceeds() public {
        (PushOracleAdapter primaryOracle,) = _setupPrimaryOracleWithETH(1200e18, 0);

        (PushOracleAdapter referenceOracle,) = _setupReferenceOracleWithETH(1000e18, 0);

        OracleDeviationGuard guard = new OracleDeviationGuard(primaryOracle, referenceOracle, 2000);

        (uint256 priceWad, uint256 updatedAt) = guard.latestPrice();

        // (1200 - 1000) / 1000 * 10_000 = 2_000 bps
        assertEq(priceWad, 1200e18);
        assertEq(updatedAt, block.timestamp);
    }

    function test_LatestPrice_DeviationBelowLimitSucceeds() public {
        (PushOracleAdapter primaryOracle,) = _setupPrimaryOracleWithETH(2000e18, 0);
        (PushOracleAdapter referenceOracle,) = _setupReferenceOracleWithETH(1900e18, 0);

        OracleDeviationGuard guard = new OracleDeviationGuard(primaryOracle, referenceOracle, 2000);

        (uint256 priceWad, uint256 updatedAt) = guard.latestPrice();

        // ceil(100 / 1900 * 10_000) = 527 bps < 2_000
        assertEq(priceWad, 2000e18);
        assertEq(updatedAt, block.timestamp);
    }

    function test_LatestPrice_Reverts_DeviationAboveLimit() public {
        (PushOracleAdapter primaryOracle,) = _setupPrimaryOracleWithETH(2000e18, 0);
        (PushOracleAdapter referenceOracle,) = _setupReferenceOracleWithETH(900e18, 0);

        OracleDeviationGuard guard = new OracleDeviationGuard(primaryOracle, referenceOracle, 2000);

        // ceil(1100 / 900 * 10_000) = 12_223 bps
        vm.expectRevert(
            abi.encodeWithSelector(OracleDeviationGuard.PriceDeviationExceeded.selector, 2000e18, 900e18, 12_223, 2000)
        );

        guard.latestPrice();
    }

    function test_LatestPrice_Reverts_DeviationOneBpsAboveLimit() public {
        (PushOracleAdapter primaryOracle,) = _setupPrimaryOracleWithETH(12_001e17, 0); // 1200.1

        (PushOracleAdapter referenceOracle,) = _setupReferenceOracleWithETH(1000e18, 0);

        OracleDeviationGuard guard = new OracleDeviationGuard(primaryOracle, referenceOracle, 2000);

        // reference = 10_000
        // primary   = 12_001
        // difference = 200.1
        // deviation = 2001 bps
        vm.expectRevert(
            abi.encodeWithSelector(OracleDeviationGuard.PriceDeviationExceeded.selector, 12_001e17, 1000e18, 2001, 2000)
        );

        guard.latestPrice();
    }

    function test_LatestPrice_PrimaryTimeBelowReference() public {
        skip(1 days);
        (PushOracleAdapter primaryOracle,) = _setupPrimaryOracleWithETH(1900e18, 1 days - 100);
        (PushOracleAdapter referenceOracle,) = _setupReferenceOracleWithETH(2000e18, 1 days - 300);

        OracleDeviationGuard guard = new OracleDeviationGuard(primaryOracle, referenceOracle, 2000);

        (uint256 priceWad, uint256 updatedAt) = guard.latestPrice();

        assertEq(priceWad, 1900e18);
        assertEq(updatedAt, 1 days - 300);
    }

    function test_LatestPrice_Reverts_ZeroReferencePrice() public {
        MockPriceOracle invalidReference = new MockPriceOracle(0, block.timestamp, bytes32("ETH"), bytes32("USD"));

        OracleDeviationGuard guard = new OracleDeviationGuard(primaryOracle, invalidReference, 2000);

        vm.expectRevert(OracleDeviationGuard.InvalidReferencePrice.selector);
        guard.latestPrice();
    }

    function test_LatestPrice_FractionalDeviationRoundsUp() public {
        MockPriceOracle primaryOracle = new MockPriceOracle(12_001, block.timestamp, bytes32("ETH"), bytes32("USD"));

        MockPriceOracle referenceOracle = new MockPriceOracle(10_000, block.timestamp, bytes32("ETH"), bytes32("USD"));

        OracleDeviationGuard guard = new OracleDeviationGuard(primaryOracle, referenceOracle, 2000);

        // 2001 / 10000 * 10000 = 2001 bps
        vm.expectRevert(
            abi.encodeWithSelector(OracleDeviationGuard.PriceDeviationExceeded.selector, 12_001, 10_000, 2001, 2000)
        );

        guard.latestPrice();
    }

    function test_LatestPrice_LargePricesDoNotOverflow() public {
        uint256 referencePrice = type(uint256).max / 20_000;
        uint256 primaryPrice = referencePrice + referencePrice / 10;

        MockPriceOracle primaryOracle =
            new MockPriceOracle(primaryPrice, block.timestamp, bytes32("ETH"), bytes32("USD"));

        MockPriceOracle referenceOracle =
            new MockPriceOracle(referencePrice, block.timestamp, bytes32("ETH"), bytes32("USD"));

        OracleDeviationGuard guard = new OracleDeviationGuard(primaryOracle, referenceOracle, 2000);

        (uint256 returnedPrice,) = guard.latestPrice();

        assertEq(returnedPrice, primaryPrice);
    }

    function _setupPrimaryOracleWithETH(int256 amount, uint256 updatedAt) private returns (PushOracleAdapter, uint256) {
        MockAggregatorV3 feedETH = new MockAggregatorV3(uint256(1), uint8(18), "MockAggregatorV3::ETH/USD");
        uint256 expectedUpdatedAt;
        if (updatedAt == 0) {
            expectedUpdatedAt = block.timestamp;
        } else {
            expectedUpdatedAt = updatedAt;
        }

        feedETH.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1, answer: amount, startedAt: block.timestamp, updatedAt: expectedUpdatedAt, answeredInRound: 1
            })
        );

        primaryOracle = new PushOracleAdapter(address(feedETH), bytes32("ETH"), bytes32("USD"), 1 hours);

        return (primaryOracle, expectedUpdatedAt);
    }

    function _setupReferenceOracleWithETH(int256 amount, uint256 updatedAt)
        private
        returns (PushOracleAdapter, uint256)
    {
        MockAggregatorV3 feedETH = new MockAggregatorV3(uint256(1), uint8(18), "MockAggregatorV3::ETH/USD");
        uint256 expectedUpdatedAt;
        if (updatedAt == 0) {
            expectedUpdatedAt = block.timestamp;
        } else {
            expectedUpdatedAt = updatedAt;
        }

        feedETH.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1, answer: amount, startedAt: block.timestamp, updatedAt: expectedUpdatedAt, answeredInRound: 1
            })
        );

        referenceOracle = new PushOracleAdapter(address(feedETH), bytes32("ETH"), bytes32("USD"), 1 hours);

        return (referenceOracle, expectedUpdatedAt);
    }

    function _setupPrimaryOracleWithWBTC() private returns (PushOracleAdapter, uint256) {
        MockAggregatorV3 feedWBTC = new MockAggregatorV3(uint256(1), uint8(8), "MockAggregatorV3::WBTC/USD");
        uint256 expectedUpdatedAt = block.timestamp;
        feedWBTC.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1,
                answer: 60_000e8,
                startedAt: block.timestamp,
                updatedAt: expectedUpdatedAt,
                answeredInRound: 1
            })
        );

        PushOracleAdapter primaryOracle1 =
            new PushOracleAdapter(address(feedWBTC), bytes32("WBTC"), bytes32("USD"), 1 hours);

        return (primaryOracle1, expectedUpdatedAt);
    }

    function _setupReferenceOracleWithUSDC2ETH() private returns (PushOracleAdapter, uint256) {
        MockAggregatorV3 feedETH = new MockAggregatorV3(uint256(1), uint8(18), "MockAggregatorV3::USD/ETH");
        uint256 expectedUpdatedAt = block.timestamp;
        feedETH.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1,
                answer: 1980e18,
                startedAt: block.timestamp,
                updatedAt: expectedUpdatedAt,
                answeredInRound: 1
            })
        );

        PushOracleAdapter referenceOracle1 =
            new PushOracleAdapter(address(feedETH), bytes32("USD"), bytes32("ETH"), 1 hours);

        return (referenceOracle1, expectedUpdatedAt);
    }

    function _setupReferenceOracleWithWBTC2ETH() private returns (PushOracleAdapter, uint256) {
        MockAggregatorV3 feedETH = new MockAggregatorV3(uint256(1), uint8(18), "MockAggregatorV3::WBTC/ETH");
        uint256 expectedUpdatedAt = block.timestamp;
        feedETH.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1,
                answer: 1980e18,
                startedAt: block.timestamp,
                updatedAt: expectedUpdatedAt,
                answeredInRound: 1
            })
        );

        PushOracleAdapter referenceOracle1 =
            new PushOracleAdapter(address(feedETH), bytes32("WBTC"), bytes32("ETH"), 1 hours);

        return (referenceOracle1, expectedUpdatedAt);
    }
}
