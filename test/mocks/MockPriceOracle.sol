// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IPriceOracle } from "src/labs/oracles/interfaces/IPriceOracle.sol";

contract MockPriceOracle is IPriceOracle {
    uint256 private immutable _price;
    uint256 private immutable _updatedAt;
    bytes32 private immutable _base;
    bytes32 private immutable _quote;

    constructor(uint256 price_, uint256 updatedAt_, bytes32 base_, bytes32 quote_) {
        _price = price_;
        _updatedAt = updatedAt_;
        _base = base_;
        _quote = quote_;
    }

    function latestPrice() external view returns (uint256 priceWad, uint256 updatedAt) {
        return (_price, _updatedAt);
    }

    function baseIdentifier() external view returns (bytes32) {
        return _base;
    }

    function quoteIdentifier() external view returns (bytes32) {
        return _quote;
    }
}
