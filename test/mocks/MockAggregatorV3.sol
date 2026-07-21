// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IAggregatorV3 } from "src/labs/oracles/interfaces/IAggregatorV3.sol";

contract MockAggregatorV3 is IAggregatorV3 {
    uint256 public immutable override version;
    uint8 public immutable override decimals;

    uint80 public latestRoundId = 1;

    struct PriceData {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    mapping(uint80 latestRoundId => PriceData) private _roundToPriceData;

    constructor(uint256 _version, uint8 _decimals) {
        version = _version;
        decimals = _decimals;
    }

    function setLatestRoundData(PriceData calldata data) external {
        latestRoundId = data.roundId;
        _roundToPriceData[data.roundId] = data;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        PriceData storage p = _roundToPriceData[latestRoundId];
        return (p.roundId, p.answer, p.startedAt, p.updatedAt, p.answeredInRound);
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        PriceData storage p = _roundToPriceData[_roundId];
        return (p.roundId, p.answer, p.startedAt, p.updatedAt, p.answeredInRound);
    }

    function description() external pure override returns (string memory) {
        return "MockAggregatorV3::ETH/USD";
    }
}
