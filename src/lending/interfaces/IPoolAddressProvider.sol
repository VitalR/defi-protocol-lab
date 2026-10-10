// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IPoolAddressProvider {
    function setPool(address newPool) external;

    function setPoolConfigurator(address newConfigurator) external;

    function setPriceOracle(address newOracle) external;

    function getPool() external view returns (address);

    function getPoolConfigurator() external view returns (address);

    function getPriceOracle() external view returns (address);
}
