// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IPoolAddressProvider } from "src/lending/interfaces/IPoolAddressProvider.sol";
import { DataTypes } from "src/lending/libraries/DataTypes.sol";

interface IPool {
    function ADDRESSES_PROVIDER() external view returns (IPoolAddressProvider);

    function initReserve(address asset) external;

    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory);

    function getReservesList() external view returns (address[] memory);

    function currentBorrowIndex(address asset) external view returns (uint256);

    function currentLiquidityIndex(address asset) external view returns (uint256);

    function supply(address asset, uint256 amount, address onBehalfOf) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256 withdrawn);
}
