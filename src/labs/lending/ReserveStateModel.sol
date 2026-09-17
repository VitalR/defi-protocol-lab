// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";

// InterestIndexModel
// LiquidityIndexModel
// ReserveFactorAccounting
// часть ScaledDebtAccounting
// часть ScaledSupplyAccounting
//         ↓
//    ReserveStateModel

// accrue old interval
// calculate current debt
// calculate current supply claims
// calculate utilization
// update borrow/liquidity indexes
// accrue treasury
// recompute rates after mutation

contract ReserveStateModel {
    error InvalidTimestamp(uint256 timestamp, uint256 lastUpdateTimestamp);
    error InvalidReserveFactor(uint256 reserveFactor);
    error InvalidIndex(uint256 index);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error ZeroAmount();

    uint256 public constant BASE_RATE = 0.02e18; // 2%
    uint256 public constant SLOPE1 = 0.04e18; // 4%;  slope1 - pre-kink slope
    uint256 public constant SLOPE2 = 0.75e18; // 75%; slope2 - post-kink slope
    uint256 public constant OPTIMAL_UTILIZATION = 0.8e18; // 80%
    uint256 public constant DEFAULT_RESERVE_FACTOR = 0.1e18; // 10%
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    uint256 internal constant WAD = 1e18;

    struct ReserveState {
        uint256 borrowIndex;
        uint256 liquidityIndex;

        uint256 totalScaledDebt;
        uint256 totalScaledSupply;

        uint256 availableLiquidity;

        uint256 accruedToTreasury;

        uint256 currentBorrowRate;
        uint256 currentLiquidityRate;

        uint256 reserveFactor;
        uint256 lastUpdateTimestamp;
    }

    ReserveState internal reserve;

    constructor() {
        reserve = ReserveState({
            borrowIndex: WAD,
            liquidityIndex: WAD,
            totalScaledDebt: 0,
            totalScaledSupply: 0,
            availableLiquidity: 0,
            accruedToTreasury: 0,
            currentBorrowRate: 0,
            currentLiquidityRate: 0,
            reserveFactor: DEFAULT_RESERVE_FACTOR,
            lastUpdateTimestamp: block.timestamp
        });
    }

    function previewBorrowIndex(uint256 timestamp) public view returns (uint256) {
        ReserveState memory state = reserve;
        uint256 lastUpdateTimestamp = state.lastUpdateTimestamp;

        require(timestamp >= lastUpdateTimestamp, InvalidTimestamp(timestamp, lastUpdateTimestamp));

        uint256 elapsed = timestamp - lastUpdateTimestamp;

        if (elapsed == 0 || state.currentBorrowRate == 0) {
            return state.borrowIndex;
        }

        uint256 growth = Math.mulDiv(state.borrowIndex, state.currentBorrowRate, 1e18, Math.Rounding.Ceil);

        growth = Math.mulDiv(growth, elapsed, SECONDS_PER_YEAR, Math.Rounding.Ceil);

        return state.borrowIndex + growth;
    }

    function utilization() public view returns (uint256) {
        uint256 debt = totalDebt();
        uint256 totalLiquidity = reserve.availableLiquidity + debt;

        if (totalLiquidity == 0) return 0;

        return DecimalMath.ratioWad(debt, totalLiquidity, Math.Rounding.Trunc);
    }

    function borrowRate() public view returns (uint256) {
        uint256 utilizationWad = utilization();

        if (utilizationWad <= OPTIMAL_UTILIZATION) {
            uint256 slopeContribution = Math.mulDiv(SLOPE1, utilizationWad, OPTIMAL_UTILIZATION, Math.Rounding.Trunc);
            return BASE_RATE + slopeContribution;
        }

        uint256 excessUtilizationWad = DecimalMath.ratioWad(
            (utilizationWad - OPTIMAL_UTILIZATION), (WAD - OPTIMAL_UTILIZATION), Math.Rounding.Trunc
        );

        uint256 postKinkContribution = Math.mulDiv(SLOPE2, excessUtilizationWad, WAD, Math.Rounding.Trunc);

        return BASE_RATE + SLOPE1 + postKinkContribution;
    }

    function liquidityRate() public view returns (uint256) {
        uint256 borrowRateWad = borrowRate();
        uint256 utilizationWad = utilization();

        uint256 reserveFactor = reserve.reserveFactor;

        if (utilizationWad == 0) return 0;

        uint256 grossRate = Math.mulDiv(borrowRateWad, utilizationWad, WAD, Math.Rounding.Trunc);

        uint256 share = WAD - reserveFactor;

        return Math.mulDiv(grossRate, share, WAD, Math.Rounding.Trunc);
    }

    function previewLiquidityIndex(uint256 timestamp) public view returns (uint256) {
        ReserveState memory state = reserve;

        require(timestamp >= state.lastUpdateTimestamp, InvalidTimestamp(timestamp, state.lastUpdateTimestamp));

        uint256 elapsed = timestamp - state.lastUpdateTimestamp;

        if (elapsed == 0 || state.currentLiquidityRate == 0) {
            return state.liquidityIndex;
        }

        uint256 growth = Math.mulDiv(state.liquidityIndex, state.currentLiquidityRate, WAD, Math.Rounding.Floor);

        growth = Math.mulDiv(growth, elapsed, SECONDS_PER_YEAR, Math.Rounding.Floor);

        return state.liquidityIndex + growth;
    }

    function accrueReserve() external {
        // settle past
        // preview both indexes
        // → calculate debt delta
        // → calculate treasury delta
        // → commit both indexes
        // → commit treasury
        // → commit timestamp
        _accrueReserve();
    }

    function setReserveState(
        uint256 totalScaledDebt,
        uint256 totalScaledSupply,
        uint256 availableLiquidity,
        uint256 currentBorrowRate,
        uint256 currentLiquidityRate,
        uint256 reserveFactor
    ) public {
        require(reserveFactor <= WAD, InvalidReserveFactor(reserveFactor));

        ReserveState storage state = reserve;

        state.totalScaledDebt = totalScaledDebt;
        state.totalScaledSupply = totalScaledSupply;
        state.availableLiquidity = availableLiquidity;
        state.currentBorrowRate = currentBorrowRate;
        state.currentLiquidityRate = currentLiquidityRate;
        state.reserveFactor = reserveFactor;
    }

    function updateScaledTotals(uint256 totalScaledDebt, uint256 totalScaledSupply) external {
        ReserveState storage state = reserve;

        state.totalScaledDebt = totalScaledDebt;
        state.totalScaledSupply = totalScaledSupply;
    }

    function updateAvailableLiquidity(uint256 availableLiquidity) external {
        ReserveState storage state = reserve;

        state.availableLiquidity = availableLiquidity;
    }

    function updateRates(uint256 currentBorrowRate, uint256 currentLiquidityRate) external {
        ReserveState storage state = reserve;

        state.currentBorrowRate = currentBorrowRate;
        state.currentLiquidityRate = currentLiquidityRate;
    }

    function getReserveState() external view returns (ReserveState memory) {
        return reserve;
    }

    function totalDebt() public view returns (uint256) {
        ReserveState storage state = reserve;

        return Math.mulDiv(state.totalScaledDebt, state.borrowIndex, WAD, Math.Rounding.Ceil);
    }

    function totalSupply() external view returns (uint256) {
        ReserveState storage state = reserve;

        return Math.mulDiv(state.totalScaledSupply, state.liquidityIndex, WAD, Math.Rounding.Floor);
    }

    function _scaledDebtToActual(uint256 scaledDebt, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(scaledDebt, index, WAD, Math.Rounding.Ceil);
    }

    // Indexes settle the past; rates price the future.
    function borrow(uint256 amount) external {
        // accrue past → mutate present → price future

        require(amount > 0, ZeroAmount());

        // settle previous interval using OLD stored rates
        _accrueReserve();

        ReserveState storage state = reserve;
        // validate available liquidity
        require(amount <= state.availableLiquidity, InsufficientLiquidity(amount, state.availableLiquidity));

        // convert amount → scaled debt using CURRENT borrowIndex
        uint256 scaledBorrowAmount = _actualDebtToScaled(amount);

        state.totalScaledDebt += scaledBorrowAmount;

        state.availableLiquidity -= amount;

        // calculate utilization from NEW reserve state
        // store rates for NEXT interval
        _updateRates();
    }

    function _accrueReserve() internal {
        // settle past
        // preview both indexes
        // → calculate debt delta
        // → calculate treasury delta
        // → commit both indexes
        // → commit treasury
        // → commit timestamp

        ReserveState storage state = reserve;

        uint256 oldBorrowIndex = state.borrowIndex;

        // uint256 oldLiquidityIndex = state.liquidityIndex;

        uint256 newBorrowIndex = previewBorrowIndex(block.timestamp);

        uint256 newLiquidityIndex = previewLiquidityIndex(block.timestamp);

        uint256 debtBefore = _scaledDebtToActual(state.totalScaledDebt, oldBorrowIndex);

        uint256 debtAfter = _scaledDebtToActual(state.totalScaledDebt, newBorrowIndex);

        uint256 borrowInterest = debtAfter - debtBefore;

        uint256 treasuryAccrual = Math.mulDiv(borrowInterest, state.reserveFactor, WAD, Math.Rounding.Floor);

        state.borrowIndex = newBorrowIndex;
        state.liquidityIndex = newLiquidityIndex;
        state.accruedToTreasury += treasuryAccrual;
        state.lastUpdateTimestamp = block.timestamp;
    }

    function _actualDebtToScaled(uint256 amount) internal view returns (uint256) {
        uint256 actualBorrowIndex = reserve.borrowIndex;

        require(actualBorrowIndex >= WAD, InvalidIndex(actualBorrowIndex));

        return Math.mulDiv(amount, WAD, actualBorrowIndex, Math.Rounding.Ceil);
    }

    function _updateRates() internal {
        uint256 newBorrowRate = borrowRate();
        uint256 newLiquidityRate = liquidityRate();

        ReserveState storage state = reserve;

        state.currentBorrowRate = newBorrowRate;
        state.currentLiquidityRate = newLiquidityRate;
    }
}
