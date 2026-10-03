// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IPoolAddressProvider } from "src/lending/interfaces/IPoolAddressProvider.sol";

interface IPoolConfigurator {
    function ADDRESSES_PROVIDER() external view returns (IPoolAddressProvider);

    function initReserve(address asset) external;
}
