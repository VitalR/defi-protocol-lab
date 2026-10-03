// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import { IPool } from "src/lending/interfaces/IPool.sol";
import { IPoolAddressProvider } from "src/lending/interfaces/IPoolAddressProvider.sol";
import { IIndexProvider } from "src/lending/interfaces/IIndexProvider.sol";
import { DataTypes } from "src/lending/libraries/DataTypes.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";
import { ScaledDebtToken } from "src/lending/tokens/ScaledDebtToken.sol";
import { ScaledSupplyToken } from "src/lending/tokens/ScaledSupplyToken.sol";
import { PoolConfigurator } from "src/lending/PoolConfigurator.sol";

contract Pool is IPool {
    error ZeroAddress();
    error ZeroAmount();
    error InvalidAddressProvider(address addressProvider);
    error InvalidConfigurator(address configurator);
    error InvalidUnderlying(address asset);
    error OnlyConfigurator(address caller);
    error UnsupportedAsset(address asset);
    error UnsupportedAssetDecimals(uint8 assetDecimals);
    error ReserveAlreadyInitialized(address asset);

    event ReserveInitialized(
        address indexed asset, address indexed supplyToken, address indexed debtToken, uint8 decimals
    );

    uint256 public constant BASE_RATE = 0.02e18; // 2%
    uint256 public constant SLOPE1 = 0.04e18; // 4%;  slope1 - pre-kink slope
    uint256 public constant SLOPE2 = 0.75e18; // 75%; slope2 - post-kink slope
    uint256 public constant OPTIMAL_UTILIZATION = 0.8e18; // 80%
    uint256 public constant DEFAULT_RESERVE_FACTOR = 0.1e18; // 10%
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    IPoolAddressProvider public immutable override ADDRESSES_PROVIDER;

    mapping(address asset => DataTypes.ReserveData reserve) internal _reserves;
    address[] internal _reservesList;

    constructor(address addressProvider) {
        require(addressProvider != address(0), ZeroAddress());

        require(addressProvider.code.length > 0, InvalidAddressProvider(addressProvider));

        ADDRESSES_PROVIDER = IPoolAddressProvider(addressProvider);
    }

    function initReserve(address asset) external {
        require(msg.sender == ADDRESSES_PROVIDER.getPoolConfigurator(), OnlyConfigurator(msg.sender));

        require(asset != address(0), ZeroAddress());

        require(asset.code.length > 0, InvalidUnderlying(asset));

        DataTypes.ReserveData storage reserve = _reserves[asset];

        require(!reserve.initialized, ReserveAlreadyInitialized(asset));

        uint8 assetDecimals = IERC20Metadata(asset).decimals();

        require(assetDecimals <= DecimalMath.WAD_DECIMALS, UnsupportedAssetDecimals(assetDecimals));

        string memory assetSymbol = IERC20Metadata(asset).symbol();

        ScaledSupplyToken supplyToken = new ScaledSupplyToken(
            address(this),
            asset,
            string.concat("Indexed Supply ", assetSymbol),
            string.concat("a", assetSymbol),
            assetDecimals
        );

        ScaledDebtToken debtToken = new ScaledDebtToken(
            address(this),
            asset,
            string.concat("Variable Debt ", assetSymbol),
            string.concat("vd", assetSymbol),
            assetDecimals
        );

        DataTypes.ReserveState storage state = reserve.state;

        state.borrowIndex = DecimalMath.WAD;
        state.liquidityIndex = DecimalMath.WAD;

        state.currentBorrowRate = BASE_RATE;
        state.currentLiquidityRate = 0;

        state.reserveFactor = DEFAULT_RESERVE_FACTOR;
        state.lastUpdateTimestamp = block.timestamp;

        reserve.supplyToken = address(supplyToken);
        reserve.debtToken = address(debtToken);
        reserve.decimals = assetDecimals;
        reserve.initialized = true;

        _reservesList.push(asset);

        emit ReserveInitialized(asset, address(supplyToken), address(debtToken), assetDecimals);
    }

    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory) {
        return _getInitializedReserve(asset);
    }

    function getReservesList() external view returns (address[] memory) {
        return _reservesList;
    }

    function currentBorrowIndex(address asset) external view returns (uint256) {
        return _getInitializedReserve(asset).state.borrowIndex;
    }

    function currentLiquidityIndex(address asset) external view returns (uint256) {
        return _getInitializedReserve(asset).state.liquidityIndex;
    }

    function _getInitializedReserve(address asset) internal view returns (DataTypes.ReserveData storage reserve) {
        reserve = _reserves[asset];

        require(reserve.initialized, UnsupportedAsset(asset));
    }
}

