// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IPriceOracle {
    function latestPrice() external view returns (uint256 priceWad, uint256 updatedAt);
}
