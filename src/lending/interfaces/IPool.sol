// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IPoolAddressProvider } from "src/lending/interfaces/IPoolAddressProvider.sol";
import { DataTypes } from "src/lending/libraries/DataTypes.sol";

interface IPool {
    function initReserve(address asset) external;

    function configureReserve(address asset, uint256 ltvWad, uint256 liquidationThresholdWad, bool borrowingEnabled)
        external;

    function supply(address asset, uint256 amount, address onBehalfOf) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256 withdrawn);

    function setUserUseReserveAsCollateral(address asset, bool enabled) external;

    function isUsingAsCollateral(address user, address asset) external view returns (bool);

    function ADDRESSES_PROVIDER() external view returns (IPoolAddressProvider);

    function getUserAccountData(address user) external view returns (DataTypes.AccountData memory);

    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory);

    function getReservesList() external view returns (address[] memory);

    function currentBorrowIndex(address asset) external view returns (uint256);

    function currentLiquidityIndex(address asset) external view returns (uint256);
}
