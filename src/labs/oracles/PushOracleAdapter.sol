// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IPriceOracle } from "src/labs/oracles/interfaces/IPriceOracle.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";
import { IAggregatorV3 } from "src/labs/oracles/interfaces/IAggregatorV3.sol";

contract PushOracleAdapter is IPriceOracle {
    error ZeroFeed();
    error ZeroMaxStaleness();
    error InvalidPair(bytes32 base, bytes32 quote);
    error UnsupportedFeedDecimals(uint8 decimals);
    error InvalidPrice(int256 answer);
    error InvalidRound(uint80 roundId);
    error IncompleteRound(uint80 roundId, uint80 answeredInRound);
    error InvalidTimestamp(uint256 updatedAt);
    error FutureTimestamp(uint256 updatedAt, uint256 currentTimestamp);
    error StalePrice(uint256 updatedAt, uint256 currentTimestamp, uint256 maxStaleness);

    bytes32 public immutable baseIdentifier; // bytes32("ETH")
    bytes32 public immutable quoteIdentifier; // bytes32("USD")

    IAggregatorV3 public immutable feed;
    uint8 public immutable feedDecimals;

    uint256 public immutable maxStaleness;

    constructor(address _feed, bytes32 _base, bytes32 _quote, uint64 _maxStaleness) {
        require(_feed != address(0), ZeroFeed());
        if (_base == bytes32(0) || _quote == bytes32(0) || _base == _quote) {
            revert InvalidPair(_base, _quote);
        }
        require(_maxStaleness != 0, ZeroMaxStaleness());

        feed = IAggregatorV3(_feed);
        feedDecimals = feed.decimals();
        if (feedDecimals > 18) revert UnsupportedFeedDecimals(feedDecimals);

        baseIdentifier = _base;
        quoteIdentifier = _quote;
        maxStaleness = _maxStaleness;
    }

    function latestPrice() external view returns (uint256 priceWad, uint256 updatedAt) {
        (uint80 roundId, int256 answer,, uint256 priceUpdatedAt, uint80 answeredInRound) = feed.latestRoundData();

        require(roundId != 0, InvalidRound(roundId));
        require(answer > 0, InvalidPrice(answer));
        require(priceUpdatedAt != 0, InvalidTimestamp(priceUpdatedAt));
        require(answeredInRound >= roundId, IncompleteRound(roundId, answeredInRound));

        uint256 currentTimestamp = block.timestamp;
        require(currentTimestamp >= priceUpdatedAt, FutureTimestamp(priceUpdatedAt, currentTimestamp));
        require(
            currentTimestamp - priceUpdatedAt <= maxStaleness,
            StalePrice(priceUpdatedAt, currentTimestamp, maxStaleness)
        );

        updatedAt = priceUpdatedAt;
        priceWad = DecimalMath.scale(uint256(answer), feedDecimals, 18, Math.Rounding.Floor);
    }
}
