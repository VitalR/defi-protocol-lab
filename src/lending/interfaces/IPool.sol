// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IPoolAddressProvider } from "src/lending/interfaces/IPoolAddressProvider.sol";
import { DataTypes } from "src/lending/libraries/DataTypes.sol";

interface IPool {
    function initReserve(address asset) external;

    function configureReserve(
        address asset,
        uint256 ltvWad,
        uint256 liquidationThresholdWad,
        uint256 liquidationBonusWad,
        bool borrowingEnabled
    ) external;

    function setReserveCaps(address asset, uint256 supplyCap, uint256 borrowCap) external;

    function setReserveFreeze(address asset, bool frozen) external;

    function setReservePause(address asset, bool paused) external;

    function supply(address asset, uint256 amount, address onBehalfOf) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256 withdrawn);

    function borrow(address asset, uint256 amount, address onBehalfOf) external;

    function repay(address asset, uint256 amount, address onBehalfOf) external returns (uint256 repaid);

    function finalizeTransfer(address asset, address from, address to) external;

    function mintToTreasury(address[] calldata assets) external;

    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveSupplyToken
    ) external returns (uint256 debtRepaid, uint256 collateralSeized);

    function setUserUseReserveAsCollateral(address asset, bool enabled) external;

    function isUsingAsCollateral(address user, address asset) external view returns (bool);

    function ADDRESSES_PROVIDER() external view returns (IPoolAddressProvider);

    function getUserAccountData(address user) external view returns (DataTypes.AccountData memory);

    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory);

    function getReservesList() external view returns (address[] memory);

    function currentBorrowIndex(address asset) external view returns (uint256);

    function currentLiquidityIndex(address asset) external view returns (uint256);
}
