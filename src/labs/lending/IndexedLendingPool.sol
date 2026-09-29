// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";
import { TokenTransfer } from "src/common/token/TokenTransfer.sol";
import { ILiquidityIndexProvider } from "src/labs/lending/interfaces/ILiquidityIndexProvider.sol";
import { IBorrowIndexProvider } from "src/labs/lending/interfaces/IBorrowIndexProvider.sol";
import { ScaledSupplyToken } from "src/labs/lending/tokens/ScaledSupplyToken.sol";
import { ScaledDebtToken } from "src/labs/lending/tokens/ScaledDebtToken.sol";

contract IndexedLendingPool is ILiquidityIndexProvider, IBorrowIndexProvider, ReentrancyGuard {
    using TokenTransfer for IERC20Metadata;

    error ZeroAddress();
    error ZeroAmount();
    error InvalidUnderlying(address underlying);
    error SupplyTooSmall(uint256 amount);

    error WithdrawExceedsSupply(uint256 requested, uint256 available);
    error InsufficientLiquidity(uint256 requested, uint256 available);

    error CurrentDebtExceeded(uint256 amount, uint256 debt);
    error DebtReductionTooSmall(uint256 amount);

    error InvalidTimestamp(uint256 timestamp, uint256 lastUpdateTimestamp);

    event Supplied(address indexed caller, address indexed onBehalfOf, uint256 actualAmount, uint256 scaledAmount);
    event Withdrawn(address indexed user, address indexed to, uint256 actualAmount, uint256 scaledAmount);
    event Borrowed(address indexed borrower, address indexed recipient, uint256 actualAmount, uint256 scaledAmount);
    event Repaid(address indexed payer, address indexed onBehalfOf, uint256 actualAmount, uint256 scaledAmount);

    uint256 public constant BASE_RATE = 0.02e18; // 2%
    uint256 public constant SLOPE1 = 0.04e18; // 4%;  slope1 - pre-kink slope
    uint256 public constant SLOPE2 = 0.75e18; // 75%; slope2 - post-kink slope
    uint256 public constant OPTIMAL_UTILIZATION = 0.8e18; // 80%
    uint256 public constant DEFAULT_RESERVE_FACTOR = 0.1e18; // 10%
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    IERC20Metadata public immutable UNDERLYING;

    ScaledSupplyToken public immutable SUPPLY_TOKEN;
    ScaledDebtToken public immutable DEBT_TOKEN;

    struct ReserveState {
        uint256 borrowIndex;
        uint256 liquidityIndex;

        uint256 availableLiquidity;
        uint256 accruedToTreasury;

        uint256 currentBorrowRate;
        uint256 currentLiquidityRate;

        uint256 reserveFactor;
        uint256 lastUpdateTimestamp;
    }

    ReserveState internal _reserve;

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    constructor(address underlying) {
        require(underlying != address(0), ZeroAddress());

        require(underlying.code.length > 0, InvalidUnderlying(underlying));

        UNDERLYING = IERC20Metadata(underlying);

        uint8 assetDecimals = IERC20Metadata(underlying).decimals();

        string memory assetSymbol = IERC20Metadata(underlying).symbol();

        SUPPLY_TOKEN = new ScaledSupplyToken(
            address(this), string.concat("Indexed Supply ", assetSymbol), string.concat("a", assetSymbol), assetDecimals
        );

        DEBT_TOKEN = new ScaledDebtToken(
            address(this), string.concat("Variable Debt ", assetSymbol), string.concat("vd", assetSymbol), assetDecimals
        );

        _reserve.liquidityIndex = DecimalMath.WAD;
        _reserve.borrowIndex = DecimalMath.WAD;

        _reserve.currentLiquidityRate = 0;
        _reserve.currentBorrowRate = BASE_RATE;

        _reserve.reserveFactor = DEFAULT_RESERVE_FACTOR;
        _reserve.lastUpdateTimestamp = block.timestamp;
    }

    // =============================================================
    //                      LENDING LOGIC
    // =============================================================

    // Supply lifecycle:
    //
    // validate
    //     ↓
    // settle reserve indexes
    //     ↓
    // actual amount → scaled amount using liquidityIndex Floor
    //     ↓
    // pull exact underlying
    //     ↓
    // mint scaled supply position
    //     ↓
    // increase available liquidity
    //     ↓
    // recalculate rates
    function supply(uint256 amount, address onBehalfOf) external nonReentrant {
        require(amount > 0, ZeroAmount());
        require(onBehalfOf != address(0), ZeroAddress());

        // settle previous interval using OLD stored rates
        _accrueReserve();
        ReserveState storage state = _reserve;

        uint256 scaledAmount = Math.mulDiv(amount, DecimalMath.WAD, state.liquidityIndex, Math.Rounding.Floor);

        require(scaledAmount > 0, SupplyTooSmall(amount));

        UNDERLYING.pullExact(msg.sender, amount);

        state.availableLiquidity += amount;

        SUPPLY_TOKEN.mintScaled(onBehalfOf, scaledAmount);

        emit Supplied(msg.sender, onBehalfOf, amount, scaledAmount);

        _updateRates();
    }

    // Withdraw lifecycle:

    // validate
    //     ↓
    // settle indexes
    //     ↓
    // read caller's current aToken balance
    //     ↓
    // check user claim
    //     ↓
    // check available liquidity
    //     ↓
    // actual withdrawal → scaled burn using Ceil
    //     ↓
    // decrease accounting
    //     ↓
    // burn aTokens
    //     ↓
    // push exact underlying
    function withdraw(uint256 amount, address to) external nonReentrant returns (uint256 withdrawnAmount) {
        require(amount > 0, ZeroAmount());
        require(to != address(0), ZeroAddress());

        _accrueReserve();
        ReserveState storage state = _reserve;

        uint256 userSupply = SUPPLY_TOKEN.balanceOf(msg.sender);

        require(amount <= userSupply, WithdrawExceedsSupply(amount, userSupply));

        require(amount <= state.availableLiquidity, InsufficientLiquidity(amount, state.availableLiquidity));

        uint256 scaledAmount;

        if (amount == userSupply) {
            // Full withdrawal must remove all scaled dust.
            scaledAmount = SUPPLY_TOKEN.scaledBalanceOf(msg.sender);
        } else {
            scaledAmount = Math.mulDiv(amount, DecimalMath.WAD, state.liquidityIndex, Math.Rounding.Ceil);
        }

        state.availableLiquidity -= amount;

        SUPPLY_TOKEN.burnScaled(msg.sender, scaledAmount);

        UNDERLYING.pushExact(to, amount);

        emit Withdrawn(msg.sender, to, amount, scaledAmount);

        withdrawnAmount = amount;

        _updateRates();
    }

    function borrow(uint256 amount, address to) external nonReentrant {
        // Checks
        require(amount > 0, ZeroAmount());
        require(to != address(0), ZeroAddress());

        _accrueReserve();
        ReserveState storage state = _reserve;

        require(amount <= state.availableLiquidity, InsufficientLiquidity(amount, state.availableLiquidity));

        uint256 scaledAmount = Math.mulDiv(amount, DecimalMath.WAD, state.borrowIndex, Math.Rounding.Ceil);

        // Effects
        state.availableLiquidity -= amount;

        // Trusted position-token interaction
        DEBT_TOKEN.mintScaled(msg.sender, scaledAmount);

        // External underlying transfer is last
        UNDERLYING.pushExact(to, amount);

        emit Borrowed(msg.sender, to, amount, scaledAmount);

        _updateRates();
    }

    function repay(uint256 amount, address onBehalfOf) external nonReentrant {
        require(amount > 0, ZeroAmount());
        require(onBehalfOf != address(0), ZeroAddress());

        _accrueReserve();
        ReserveState storage state = _reserve;

        uint256 userDebt = DEBT_TOKEN.balanceOf(onBehalfOf);
        require(amount <= userDebt, CurrentDebtExceeded(amount, userDebt));

        uint256 scaledAmount;
        if (amount == userDebt) {
            // Full repayment clears all scaled dust
            scaledAmount = DEBT_TOKEN.scaledBalanceOf(onBehalfOf);
        } else {
            scaledAmount = Math.mulDiv(amount, DecimalMath.WAD, state.borrowIndex, Math.Rounding.Floor);

            require(scaledAmount > 0, DebtReductionTooSmall(amount));
        }

        // Effects
        state.availableLiquidity += amount;

        // Burn debt belonging to onBehalfOf
        DEBT_TOKEN.burnScaled(onBehalfOf, scaledAmount);

        // The caller always provides underlying
        UNDERLYING.pullExact(msg.sender, amount);

        emit Repaid(msg.sender, onBehalfOf, amount, scaledAmount);

        _updateRates();
    }

    // =============================================================
    //                       INTERNAL HELPERS
    // =============================================================

    function _accrueReserve() internal {
        ReserveState storage state = _reserve;

        uint256 oldBorrowIndex = state.borrowIndex;
        uint256 newBorrowIndex = _previewBorrowIndex(block.timestamp);
        uint256 newLiquidityIndex = _previewLiquidityIndex(block.timestamp);

        uint256 scaledDebt = DEBT_TOKEN.scaledTotalSupply();

        uint256 debtBefore = _scaledDebtToActual(scaledDebt, oldBorrowIndex);
        uint256 debtAfter = _scaledDebtToActual(scaledDebt, newBorrowIndex);

        uint256 borrowInterest = debtAfter - debtBefore;

        uint256 treasuryAccrual = Math.mulDiv(borrowInterest, state.reserveFactor, DecimalMath.WAD, Math.Rounding.Floor);

        state.borrowIndex = newBorrowIndex;
        state.liquidityIndex = newLiquidityIndex;

        state.accruedToTreasury += treasuryAccrual;

        if (block.timestamp == state.lastUpdateTimestamp) return;
        state.lastUpdateTimestamp = block.timestamp;
    }

    function _updateRates() internal {
        ReserveState storage state = _reserve;

        uint256 debt = _totalDebtAtIndex(state.borrowIndex);

        uint256 utilizationWad = _utilization(state.availableLiquidity, debt);

        uint256 newBorrowRate = _borrowRate(utilizationWad);

        uint256 newLiquidityRate = _liquidityRate(newBorrowRate, utilizationWad);

        state.currentBorrowRate = newBorrowRate;
        state.currentLiquidityRate = newLiquidityRate;
    }

    function _previewLiquidityIndex(uint256 timestamp) internal view returns (uint256) {
        ReserveState storage state = _reserve;

        require(timestamp >= state.lastUpdateTimestamp, InvalidTimestamp(timestamp, state.lastUpdateTimestamp));

        uint256 elapsed = timestamp - state.lastUpdateTimestamp;
        if (elapsed == 0 || state.currentLiquidityRate == 0) {
            return state.liquidityIndex;
        }

        uint256 growth =
            Math.mulDiv(state.liquidityIndex, state.currentLiquidityRate, DecimalMath.WAD, Math.Rounding.Floor);
        growth = Math.mulDiv(growth, elapsed, SECONDS_PER_YEAR, Math.Rounding.Floor);

        return state.liquidityIndex + growth;
    }

    function _previewBorrowIndex(uint256 timestamp) internal view returns (uint256) {
        ReserveState storage state = _reserve;
        uint256 lastUpdateTimestamp = state.lastUpdateTimestamp;

        require(timestamp >= lastUpdateTimestamp, InvalidTimestamp(timestamp, lastUpdateTimestamp));

        uint256 elapsed = timestamp - lastUpdateTimestamp;
        if (elapsed == 0 || state.currentBorrowRate == 0) {
            return state.borrowIndex;
        }

        uint256 growth = Math.mulDiv(state.borrowIndex, state.currentBorrowRate, DecimalMath.WAD, Math.Rounding.Ceil);
        growth = Math.mulDiv(growth, elapsed, SECONDS_PER_YEAR, Math.Rounding.Ceil);

        return state.borrowIndex + growth;
    }

    function _currentLiquidityIndex() internal view returns (uint256) {
        return _previewLiquidityIndex(block.timestamp);
    }

    function _currentBorrowIndex() internal view returns (uint256) {
        return _previewBorrowIndex(block.timestamp);
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

    function _liquidityRate(uint256 borrowRateWad, uint256 utilizationWad) internal view returns (uint256) {
        if (utilizationWad == 0) return 0;

        uint256 grossRate = Math.mulDiv(borrowRateWad, utilizationWad, DecimalMath.WAD, Math.Rounding.Trunc);

        uint256 share = DecimalMath.WAD - _reserve.reserveFactor;

        return Math.mulDiv(grossRate, share, DecimalMath.WAD, Math.Rounding.Trunc);
    }

    function _utilization(uint256 liquidity, uint256 debt) internal pure returns (uint256) {
        uint256 totalLiquidity = liquidity + debt;

        if (totalLiquidity == 0) return 0;

        return DecimalMath.ratioWad(debt, totalLiquidity, Math.Rounding.Trunc);
    }

    function _scaledDebtToActual(uint256 scaledDebt, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(scaledDebt, index, DecimalMath.WAD, Math.Rounding.Ceil);
    }

    function _totalDebtAtIndex(uint256 index) internal view returns (uint256) {
        return Math.mulDiv(DEBT_TOKEN.scaledTotalSupply(), index, DecimalMath.WAD, Math.Rounding.Ceil);
    }

    // =============================================================
    //                          READ API
    // =============================================================

    function availableLiquidity() public view returns (uint256) {
        return _reserve.availableLiquidity;
    }

    function utilization() public view returns (uint256) {
        uint256 debt = totalDebt();
        uint256 totalLiquidity = availableLiquidity() + debt;

        if (totalLiquidity == 0) return 0;

        return DecimalMath.ratioWad(debt, totalLiquidity, Math.Rounding.Trunc);
    }

    function borrowRate() public view returns (uint256) {
        uint256 utilizationWad = utilization();

        return _borrowRate(utilizationWad);
    }

    function liquidityRate() public view returns (uint256) {
        uint256 borrowRateWad = borrowRate();
        uint256 utilizationWad = utilization();

        return _liquidityRate(borrowRateWad, utilizationWad);
    }

    function currentLiquidityIndex() external view override returns (uint256) {
        return _currentLiquidityIndex();
    }

    function currentBorrowIndex() external view override returns (uint256) {
        return _currentBorrowIndex();
    }

    function getReserveState() external view returns (ReserveState memory) {
        return _reserve;
    }

    function totalScaledSupply() public view returns (uint256) {
        return SUPPLY_TOKEN.scaledTotalSupply();
    }

    function totalScaledDebt() public view returns (uint256) {
        return DEBT_TOKEN.scaledTotalSupply();
    }

    function totalSupply() public view returns (uint256) {
        return
            Math.mulDiv(
                SUPPLY_TOKEN.scaledTotalSupply(), _currentLiquidityIndex(), DecimalMath.WAD, Math.Rounding.Floor
            );
    }

    function totalDebt() public view returns (uint256) {
        return Math.mulDiv(DEBT_TOKEN.scaledTotalSupply(), _currentBorrowIndex(), DecimalMath.WAD, Math.Rounding.Ceil);
    }

    function unaccountedCash() external view returns (uint256) {
        uint256 cash = UNDERLYING.balanceOf(address(this));

        return cash > availableLiquidity() ? cash - availableLiquidity() : 0;
    }
}
