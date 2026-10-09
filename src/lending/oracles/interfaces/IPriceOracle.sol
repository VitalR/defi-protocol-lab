// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IPriceOracle {
    function baseIdentifier() external view returns (bytes32);

    function quoteIdentifier() external view returns (bytes32);

    function latestPrice() external view returns (uint256 priceWad, uint256 updatedAt);
}
