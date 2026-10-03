// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IPoolAddressProvider {
    function getPool() external view returns (address);

    function getPoolConfigurator() external view returns (address);
}
