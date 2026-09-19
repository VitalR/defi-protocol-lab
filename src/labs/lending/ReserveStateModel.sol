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
//
// ==============================
//
// Core reserve lifecycle:
//
// Supply   → liquidity ↑ → utilization ↓ → rates ↓
// Withdraw → liquidity ↓ → utilization ↑ → rates ↑

// Borrow   → liquidity ↓ + debt ↑ → utilization ↑ → rates ↑
// Repay    → liquidity ↑ + debt ↓ → utilization ↓ → rates ↓

// Time     → indexes ↑
//          → debt / supplier claims ↑
//          → treasury accrues

contract ReserveStateModel {
    error InvalidTimestamp(uint256 timestamp, uint256 lastUpdateTimestamp);
    error InvalidReserveFactor(uint256 reserveFactor);
    error InvalidIndex(uint256 index);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error CurrentDebtExceeded(uint256 amount, uint256 debt);
    error WithdrawExceedsSupply(uint256 amount, uint256 currentSupply);
    error SupplyTooSmall(uint256 amount);
    error DebtReductionTooSmall(uint256 amount);
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

    // LAB ONLY:
    // unrestricted setup helpers for isolated testing;
    // not part of a production reserve API.
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

    function updateRates(uint256 currentBorrowRate, uint256 currentLiquidityRate) external {
        ReserveState storage state = reserve;

        state.currentBorrowRate = currentBorrowRate;
        state.currentLiquidityRate = currentLiquidityRate;
    }

    // ==============================
    // RESERVE STATE MANAGEMENT LOGIC
    // ==============================

    // BORROW:
    // accrue
    // → scaled debt mint CEIL
    // → available ↓
    // → update rates

    // REPAY:
    // accrue
    // → scaled debt burn FLOOR
    // → available ↑
    // → update rates

    // SUPPLY:
    // accrue
    // → scaled supply mint FLOOR
    // → available ↑
    // → update rates

    // WITHDRAW:
    // accrue
    // → scaled supply burn CEIL
    // → available ↓
    // → update rates

    function borrow(uint256 amount) external {
        // accrue past → mutate present → price future

        require(amount > 0, ZeroAmount());

        // settle previous interval using OLD stored rates
        _accrueReserve();

        ReserveState storage state = reserve;
        // validate available liquidity
        require(amount <= state.availableLiquidity, InsufficientLiquidity(amount, state.availableLiquidity));

        // convert amount → scaled debt using CURRENT borrowIndex
        uint256 scaledBorrowAmount = _actualDebtToScaledBorrow(amount);

        state.totalScaledDebt += scaledBorrowAmount;

        state.availableLiquidity -= amount;

        // calculate utilization from NEW reserve state
        // store rates for NEXT interval
        _updateRates();
    }

    function repay(uint256 amount) external {
        require(amount > 0, ZeroAmount());

        _accrueReserve();

        ReserveState storage state = reserve;

        uint256 debt = totalDebt();

        require(amount <= debt, CurrentDebtExceeded(amount, debt));

        if (amount == debt) {
            state.totalScaledDebt = 0;
        } else {
            uint256 scaledRepayAmount = _actualDebtToScaledRepay(amount);

            require(scaledRepayAmount > 0, DebtReductionTooSmall(amount));

            state.totalScaledDebt -= scaledRepayAmount;
        }

        state.availableLiquidity += amount;

        _updateRates();
    }

    function supply(uint256 amount) external {
        require(amount > 0, ZeroAmount());

        _accrueReserve();

        ReserveState storage state = reserve;

        uint256 scaledMint = _actualSupplyToScaledMint(amount);

        require(scaledMint > 0, SupplyTooSmall(amount));

        state.totalScaledSupply += scaledMint;
        state.availableLiquidity += amount;

        _updateRates();
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, ZeroAmount());

        _accrueReserve();

        ReserveState storage state = reserve;

        uint256 supply = totalSupply();

        require(amount <= supply, WithdrawExceedsSupply(amount, supply));

        require(amount <= state.availableLiquidity, InsufficientLiquidity(amount, state.availableLiquidity));

        if (amount == supply) {
            state.totalScaledSupply = 0;
        } else {
            uint256 scaledBurn = _actualSupplyToScaledBurn(amount);

            state.totalScaledSupply -= scaledBurn;
        }

        state.availableLiquidity -= amount;

        _updateRates();
    }

    // Indexes settle the past; rates price the future.
    function accrueReserve() external {
        _accrueReserve();
    }

    // accrue past → mutate present → price future
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

    function utilization() public view returns (uint256) {
        uint256 debt = totalDebt();
        uint256 totalLiquidity = reserve.availableLiquidity + debt;

        if (totalLiquidity == 0) return 0;

        return DecimalMath.ratioWad(debt, totalLiquidity, Math.Rounding.Trunc);
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

    function getReserveState() external view returns (ReserveState memory) {
        return reserve;
    }

    function totalDebt() public view returns (uint256) {
        ReserveState storage state = reserve;

        return Math.mulDiv(state.totalScaledDebt, state.borrowIndex, WAD, Math.Rounding.Ceil);
    }

    function totalSupply() public view returns (uint256) {
        ReserveState storage state = reserve;

        return Math.mulDiv(state.totalScaledSupply, state.liquidityIndex, WAD, Math.Rounding.Floor);
    }

    function currentTotalSupply() public view returns (uint256) {
        uint256 currentIndex = previewLiquidityIndex(block.timestamp);

        return Math.mulDiv(reserve.totalScaledSupply, currentIndex, WAD, Math.Rounding.Floor);
    }

    function currentTotalDebt() public view returns (uint256) {
        uint256 currentIndex = previewBorrowIndex(block.timestamp);

        return Math.mulDiv(reserve.totalScaledDebt, currentIndex, WAD, Math.Rounding.Ceil);
    }

    function _scaledDebtToActual(uint256 scaledDebt, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(scaledDebt, index, WAD, Math.Rounding.Ceil);
    }

    function _actualDebtToScaledBorrow(uint256 amount) internal view returns (uint256) {
        uint256 actualBorrowIndex = reserve.borrowIndex;

        require(actualBorrowIndex >= WAD, InvalidIndex(actualBorrowIndex));

        return Math.mulDiv(amount, WAD, actualBorrowIndex, Math.Rounding.Ceil);
    }

    function _actualDebtToScaledRepay(uint256 amount) internal view returns (uint256) {
        uint256 actualBorrowIndex = reserve.borrowIndex;

        require(actualBorrowIndex >= WAD, InvalidIndex(actualBorrowIndex));

        return Math.mulDiv(amount, WAD, actualBorrowIndex, Math.Rounding.Floor);
    }

    function _actualSupplyToScaledMint(uint256 amount) internal view returns (uint256) {
        uint256 actualLiquidityIndex = reserve.liquidityIndex;

        require(actualLiquidityIndex >= WAD, InvalidIndex(actualLiquidityIndex));

        return Math.mulDiv(amount, WAD, actualLiquidityIndex, Math.Rounding.Floor);
    }

    function _actualSupplyToScaledBurn(uint256 amount) internal view returns (uint256) {
        uint256 actualLiquidityIndex = reserve.liquidityIndex;

        require(actualLiquidityIndex >= WAD, InvalidIndex(actualLiquidityIndex));

        return Math.mulDiv(amount, WAD, actualLiquidityIndex, Math.Rounding.Ceil);
    }

    function _updateRates() internal {
        uint256 newBorrowRate = borrowRate();
        uint256 newLiquidityRate = liquidityRate();

        ReserveState storage state = reserve;

        state.currentBorrowRate = newBorrowRate;
        state.currentLiquidityRate = newLiquidityRate;
    }
}
