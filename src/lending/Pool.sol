// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IPool } from "src/lending/interfaces/IPool.sol";
import { IPoolAddressProvider } from "src/lending/interfaces/IPoolAddressProvider.sol";
import { IIndexProvider } from "src/lending/interfaces/IIndexProvider.sol";
import { DataTypes } from "src/lending/libraries/DataTypes.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";
import { TokenTransfer } from "src/common/token/TokenTransfer.sol";
import { ScaledDebtToken } from "src/lending/tokens/ScaledDebtToken.sol";
import { ScaledSupplyToken } from "src/lending/tokens/ScaledSupplyToken.sol";
import { PoolConfigurator } from "src/lending/PoolConfigurator.sol";

contract Pool is IPool, ReentrancyGuard {
    using TokenTransfer for IERC20Metadata;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidAddressProvider(address addressProvider);
    error InvalidConfigurator(address configurator);
    error InvalidUnderlying(address asset);
    error OnlyConfigurator(address caller);
    error UnsupportedAsset(address asset);
    error UnsupportedAssetDecimals(uint8 assetDecimals);
    error ReserveAlreadyInitialized(address asset);
    error ReserveNotInitialized(address asset);
    error SupplyTooSmall(uint256 amount);
    error InvalidTimestamp(uint256 timestamp, uint256 lastUpdateTimestamp);
    error WithdrawExceedsSupply(uint256 requested, uint256 available);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error InvalidParams();

    event ReserveInitialized(
        address indexed asset, address indexed supplyToken, address indexed debtToken, uint8 decimals
    );
    event ReserveConfigured(
        address indexed asset, uint256 ltvWad, uint256 liquidationThresholdWad, bool borrowingEnabled
    );
    event Supplied(
        address indexed asset,
        address indexed caller,
        address indexed onBehalfOf,
        uint256 actualAmount,
        uint256 scaledAmount
    );
    event Withdrawn(
        address indexed asset, address indexed user, address indexed to, uint256 actualAmount, uint256 scaledAmount
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

    modifier onlyConfigurator() {
        require(msg.sender == ADDRESSES_PROVIDER.getPoolConfigurator(), OnlyConfigurator(msg.sender));
        _;
    }

    constructor(address addressProvider) {
        require(addressProvider != address(0), ZeroAddress());

        require(addressProvider.code.length > 0, InvalidAddressProvider(addressProvider));

        ADDRESSES_PROVIDER = IPoolAddressProvider(addressProvider);
    }

    function initReserve(address asset) external onlyConfigurator {
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

    function configureReserve(address asset, uint256 ltvWad, uint256 liquidationThresholdWad, bool borrowingEnabled)
        external
        onlyConfigurator
    {
        require(asset != address(0), ZeroAddress());

        require(asset.code.length > 0, InvalidUnderlying(asset));

        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        require(ltvWad <= liquidationThresholdWad && liquidationThresholdWad <= DecimalMath.WAD, InvalidParams());

        DataTypes.ReserveConfiguration storage config = reserve.configuration;

        config.ltvWad = ltvWad;
        config.liquidationThresholdWad = liquidationThresholdWad;
        config.borrowingEnabled = borrowingEnabled;

        emit ReserveConfigured(asset, config.ltvWad, config.liquidationThresholdWad, config.borrowingEnabled);
    }

    function supply(address asset, uint256 amount, address onBehalfOf) external nonReentrant {
        require(asset != address(0) && onBehalfOf != address(0), ZeroAddress());
        require(amount > 0, ZeroAmount());

        _accrueReserve(asset);

        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        uint256 scaledAmount = Math.mulDiv(amount, DecimalMath.WAD, reserve.state.liquidityIndex, Math.Rounding.Floor);

        require(scaledAmount > 0, SupplyTooSmall(amount));

        IERC20Metadata(asset).pullExactTo(msg.sender, address(reserve.supplyToken), amount);

        reserve.state.availableLiquidity += amount;

        ScaledSupplyToken(reserve.supplyToken).mintScaled(onBehalfOf, scaledAmount);

        _updateRates(asset);

        emit Supplied(asset, msg.sender, onBehalfOf, amount, scaledAmount);
    }

    function withdraw(address asset, uint256 amount, address to) external nonReentrant returns (uint256 withdrawn) {
        require(asset != address(0) && to != address(0), ZeroAddress());
        require(amount > 0, ZeroAmount());

        _accrueReserve(asset);

        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);
        ScaledSupplyToken supplyToken = ScaledSupplyToken(reserve.supplyToken);

        uint256 userScaledSupply = supplyToken.scaledBalanceOf(msg.sender);
        uint256 userSupply =
            Math.mulDiv(userScaledSupply, reserve.state.liquidityIndex, DecimalMath.WAD, Math.Rounding.Floor);

        withdrawn = amount == type(uint256).max ? userSupply : amount;

        require(withdrawn > 0, ZeroAmount());
        require(withdrawn <= userSupply, WithdrawExceedsSupply(withdrawn, userSupply));
        require(
            withdrawn <= reserve.state.availableLiquidity,
            InsufficientLiquidity(withdrawn, reserve.state.availableLiquidity)
        );

        uint256 scaledAmount = withdrawn == userSupply
            ? userScaledSupply
            : Math.mulDiv(withdrawn, DecimalMath.WAD, reserve.state.liquidityIndex, Math.Rounding.Ceil);

        reserve.state.availableLiquidity -= withdrawn;

        supplyToken.burnScaled(msg.sender, scaledAmount);

        supplyToken.transferUnderlyingTo(to, withdrawn);

        _updateRates(asset);

        emit Withdrawn(asset, msg.sender, to, withdrawn, scaledAmount);
    }

    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory) {
        return _getInitializedReserve(asset);
    }

    function getReservesList() external view returns (address[] memory) {
        return _reservesList;
    }

    function currentBorrowIndex(address asset) external view returns (uint256) {
        return _currentBorrowIndex(asset);
    }

    function currentLiquidityIndex(address asset) external view returns (uint256) {
        return _currentLiquidityIndex(asset);
    }

    function availableLiquidity(address asset) public view returns (uint256) {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        return reserve.state.availableLiquidity;
    }

    function totalScaledSupply(address asset) public view returns (uint256) {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        return ScaledSupplyToken(reserve.supplyToken).scaledTotalSupply();
    }

    function totalScaledDebt(address asset) public view returns (uint256) {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        return ScaledDebtToken(reserve.debtToken).scaledTotalSupply();
    }

    function totalSupply(address asset) public view returns (uint256) {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        return Math.mulDiv(
            ScaledSupplyToken(reserve.supplyToken).scaledTotalSupply(),
            _currentLiquidityIndex(asset),
            DecimalMath.WAD,
            Math.Rounding.Floor
        );
    }

    function totalDebt(address asset) public view returns (uint256) {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        return Math.mulDiv(
            ScaledDebtToken(reserve.debtToken).scaledTotalSupply(),
            _currentBorrowIndex(asset),
            DecimalMath.WAD,
            Math.Rounding.Ceil
        );
    }

    function utilization(address asset) public view returns (uint256) {
        uint256 debt = totalDebt(asset);
        uint256 totalLiquidity = availableLiquidity(asset) + debt;

        if (totalLiquidity == 0) return 0;

        return DecimalMath.ratioWad(debt, totalLiquidity, Math.Rounding.Trunc);
    }

    function borrowRate(address asset) public view returns (uint256) {
        uint256 utilizationWad = utilization(asset);

        return _borrowRate(utilizationWad);
    }

    function liquidityRate(address asset) public view returns (uint256) {
        uint256 borrowRateWad = borrowRate(asset);
        uint256 utilizationWad = utilization(asset);

        return _liquidityRate(asset, borrowRateWad, utilizationWad);
    }

    function unaccountedCash(address asset) external view returns (uint256) {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        uint256 cash = IERC20Metadata(asset).balanceOf(address(reserve.supplyToken));

        return cash > availableLiquidity(asset) ? cash - availableLiquidity(asset) : 0;
    }

    function _accrueReserve(address asset) internal {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        if (block.timestamp == reserve.state.lastUpdateTimestamp) return;

        uint256 oldBorrowIndex = reserve.state.borrowIndex;
        uint256 newBorrowIndex = _previewBorrowIndex(asset, block.timestamp);
        uint256 newLiquidityIndex = _previewLiquidityIndex(asset, block.timestamp);

        uint256 scaledDebt = ScaledDebtToken(reserve.debtToken).scaledTotalSupply();

        uint256 debtBefore = _scaledDebtToActual(scaledDebt, oldBorrowIndex);
        uint256 debtAfter = _scaledDebtToActual(scaledDebt, newBorrowIndex);

        uint256 borrowInterest = debtAfter - debtBefore;

        uint256 treasuryAccrual =
            Math.mulDiv(borrowInterest, reserve.state.reserveFactor, DecimalMath.WAD, Math.Rounding.Floor);

        reserve.state.accruedToTreasury += treasuryAccrual;

        reserve.state.borrowIndex = newBorrowIndex;
        reserve.state.liquidityIndex = newLiquidityIndex;
        reserve.state.lastUpdateTimestamp = block.timestamp;
    }

    function _updateRates(address asset) internal {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        uint256 debt = _totalDebtAtIndex(asset, reserve.state.borrowIndex);

        uint256 utilizationWad = _utilization(reserve.state.availableLiquidity, debt);

        uint256 newBorrowRate = _borrowRate(utilizationWad);

        uint256 newLiquidityRate = _liquidityRate(asset, newBorrowRate, utilizationWad);

        reserve.state.currentBorrowRate = newBorrowRate;
        reserve.state.currentLiquidityRate = newLiquidityRate;
    }

    function _previewBorrowIndex(address asset, uint256 timestamp) internal view returns (uint256) {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        require(
            timestamp >= reserve.state.lastUpdateTimestamp,
            InvalidTimestamp(timestamp, reserve.state.lastUpdateTimestamp)
        );

        uint256 elapsed = timestamp - reserve.state.lastUpdateTimestamp;
        if (elapsed == 0) return reserve.state.borrowIndex;

        uint256 growth = Math.mulDiv(
            reserve.state.borrowIndex, reserve.state.currentBorrowRate, DecimalMath.WAD, Math.Rounding.Ceil
        );
        growth = Math.mulDiv(growth, elapsed, SECONDS_PER_YEAR, Math.Rounding.Ceil);

        return reserve.state.borrowIndex + growth;
    }

    function _previewLiquidityIndex(address asset, uint256 timestamp) internal view returns (uint256) {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        require(
            timestamp >= reserve.state.lastUpdateTimestamp,
            InvalidTimestamp(timestamp, reserve.state.lastUpdateTimestamp)
        );

        uint256 elapsed = timestamp - reserve.state.lastUpdateTimestamp;
        if (elapsed == 0) return reserve.state.liquidityIndex;

        uint256 growth = Math.mulDiv(
            reserve.state.liquidityIndex, reserve.state.currentLiquidityRate, DecimalMath.WAD, Math.Rounding.Floor
        );
        growth = Math.mulDiv(growth, elapsed, SECONDS_PER_YEAR, Math.Rounding.Floor);

        return reserve.state.liquidityIndex + growth;
    }

    function _utilization(uint256 liquidity, uint256 debt) internal pure returns (uint256) {
        uint256 totalLiquidity = liquidity + debt;

        if (totalLiquidity == 0) return 0;

        return DecimalMath.ratioWad(debt, totalLiquidity, Math.Rounding.Trunc);
    }

    function _borrowRate(uint256 utilizationWad) internal pure returns (uint256) {
        if (utilizationWad <= OPTIMAL_UTILIZATION) {
            uint256 slopeContribution = Math.mulDiv(SLOPE1, utilizationWad, OPTIMAL_UTILIZATION, Math.Rounding.Trunc);
            return BASE_RATE + slopeContribution;
        }
        uint256 excessUtilizationWad = DecimalMath.ratioWad(
            (utilizationWad - OPTIMAL_UTILIZATION), (DecimalMath.WAD - OPTIMAL_UTILIZATION), Math.Rounding.Trunc
        );

        uint256 postKinkContribution = Math.mulDiv(SLOPE2, excessUtilizationWad, DecimalMath.WAD, Math.Rounding.Trunc);

        return BASE_RATE + SLOPE1 + postKinkContribution;
    }

    function _liquidityRate(address asset, uint256 borrowRateWad, uint256 utilizationWad)
        internal
        view
        returns (uint256)
    {
        if (utilizationWad == 0) return 0;

        uint256 grossRate = Math.mulDiv(borrowRateWad, utilizationWad, DecimalMath.WAD, Math.Rounding.Trunc);

        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        uint256 share = DecimalMath.WAD - reserve.state.reserveFactor;

        return Math.mulDiv(grossRate, share, DecimalMath.WAD, Math.Rounding.Trunc);
    }

    function _scaledDebtToActual(uint256 scaledDebt, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(scaledDebt, index, DecimalMath.WAD, Math.Rounding.Ceil);
    }

    function _totalDebtAtIndex(address asset, uint256 index) internal view returns (uint256) {
        DataTypes.ReserveData storage reserve = _getInitializedReserve(asset);

        return Math.mulDiv(
            ScaledDebtToken(reserve.debtToken).scaledTotalSupply(), index, DecimalMath.WAD, Math.Rounding.Ceil
        );
    }

    function _getInitializedReserve(address asset) internal view returns (DataTypes.ReserveData storage reserve) {
        reserve = _reserves[asset];

        require(reserve.initialized, UnsupportedAsset(asset));
    }

    function _currentBorrowIndex(address asset) internal view returns (uint256) {
        return _previewBorrowIndex(asset, block.timestamp);
    }

    function _currentLiquidityIndex(address asset) internal view returns (uint256) {
        return _previewLiquidityIndex(asset, block.timestamp);
    }
}

