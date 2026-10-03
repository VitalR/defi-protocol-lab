// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IPool } from "src/lending/interfaces/IPool.sol";
import { IPoolAddressProvider } from "src/lending/interfaces/IPoolAddressProvider.sol";
import { IPoolConfigurator } from "src/lending/interfaces/IPoolConfigurator.sol";

contract PoolAddressProvider is IPoolAddressProvider, Ownable2Step {
    error ZeroAddress();
    error InvalidPool(address pool);
    error InvalidConfigurator(address poolConfigurator);
    error PoolAlreadyRegistered(address pool);
    error AddressProviderMismatch(address addressProvider, address candidateProvider);

    event PoolSet(address oldPool, address newPool);
    event PoolConfiguratorSet(address oldConfigurator, address newConfigurator);

    address internal _pool;
    address internal _configurator;

    constructor(address admin) Ownable(admin) { }

    function setPool(address newPool) external onlyOwner {
        require(_pool == address(0), PoolAlreadyRegistered(_pool));
        require(newPool != address(0), ZeroAddress());
        require(newPool.code.length > 0, InvalidPool(newPool));

        address candidateProvider = address(IPool(newPool).ADDRESSES_PROVIDER());
        require(candidateProvider == address(this), AddressProviderMismatch(address(this), candidateProvider));

        address oldPool = _pool;

        _pool = newPool;

        emit PoolSet(oldPool, newPool);
    }

    function setPoolConfigurator(address newConfigurator) external onlyOwner {
        require(newConfigurator != address(0), ZeroAddress());
        require(newConfigurator.code.length > 0, InvalidConfigurator(newConfigurator));

        address candidateProvider = address(IPoolConfigurator(newConfigurator).ADDRESSES_PROVIDER());
        require(candidateProvider == address(this), AddressProviderMismatch(address(this), candidateProvider));

        address oldConfigurator = _configurator;

        _configurator = newConfigurator;

        emit PoolConfiguratorSet(oldConfigurator, newConfigurator);
    }

    function getPool() external view returns (address) {
        return _pool;
    }

    function getPoolConfigurator() external view returns (address) {
        return _configurator;
    }
}
