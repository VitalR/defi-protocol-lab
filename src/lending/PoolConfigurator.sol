// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IPoolAddressProvider } from "src/lending/interfaces/IPoolAddressProvider.sol";
import { IPool } from "src/lending/interfaces/IPool.sol";

contract PoolConfigurator is Ownable2Step {
    error ZeroAddress();
    error PoolNotConfigured();
    error InvalidAddressProvider(address addressProvider);

    IPoolAddressProvider public immutable ADDRESSES_PROVIDER;

    constructor(address admin, address addressProvider) Ownable(admin) {
        require(addressProvider != address(0), ZeroAddress());
        require(addressProvider.code.length > 0, InvalidAddressProvider(addressProvider));

        ADDRESSES_PROVIDER = IPoolAddressProvider(addressProvider);
    }

    function initReserve(address asset) external onlyOwner {
        require(asset != address(0), ZeroAddress());

        address pool = ADDRESSES_PROVIDER.getPool();

        require(pool != address(0), PoolNotConfigured());

        IPool(pool).initReserve(asset);
    }
}
