// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IPriceOracle } from "src/labs/oracles/interfaces/IPriceOracle.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";
import { TokenTransfer, IERC20 } from "src/common/token/TokenTransfer.sol";
import { InterestRateModel } from "src/labs/lending/InterestRateModel.sol";

contract SimpleLendingPool {
    error ZeroAddress();
    error ZeroAmount();
    error BorrowCapacityExceeded(uint256 requestedDebt, uint256 maxDebt);
    error InsufficientCollateral(uint256 requested, uint256 available);
    error UnhealthyPosition(uint256 healthFactor);
    error CurrentDebtExceeded(uint256 requestedRepay, uint256 currectDebt);
    error PositionNotLiquidatable(uint256 healthFactor);
    error DebtToRepayExceedsMaxLiquidatableDebt(uint256 debtToRepay, uint256 maxLiqDebt);
    error SeizeMoreThanBorrowerOwns(uint256 collateralToSeize, uint256 currentCollateral);
    error InvalidTimestamp(uint256 timestamp, uint256 lastUpdateTimestamp);
    error InvalidIndex(uint256 index);
    error DebtReductionTooSmall(uint256 amount);

    event Supplied(address indexed user, address indexed collateralToken, uint256 amount);
    event Borrowed(address indexed user, address indexed debtToken, uint256 amount);
    event Withdrawn(address indexed user, address indexed collateralToken, uint256 amount);
    event Repaid(address indexed user, address indexed debtToken, uint256 amount);
    event Liquidated(
        address indexed liquidator, address indexed borrower, uint256 debtToRepay, uint256 collateralToSeize
    );

    IERC20 public immutable collateralToken; // WETH
    IERC20 public immutable debtToken; // USDC

    IPriceOracle public immutable oracle;

    uint256 public constant LTV = 7500; // 75%
    uint256 public constant LIQUIDATION_THRESHOLD = 8000; // 80%
    uint256 public constant LIQUIDATION_BONUS = 500; // 5%
    uint256 public constant CLOSE_FACTOR = 5000; // 50%

    uint256 public constant SECONDS_PER_YEAR = 365 days;

    uint256 private constant BPS = 10_000;

    uint8 public immutable collateralTokenDecimals;
    uint8 public immutable debtTokenDecimals;

    InterestRateModel public immutable interestRateModel;

    uint256 public borrowIndex;
    uint256 public lastInterestUpdate;
    uint256 public totalScaledDebt;

    mapping(address user => uint256 amount) private _scaledDebt;
    mapping(address user => uint256 amount) private _collateralBalance;

    constructor(address _collateralToken, address _debtToken, address _oracle, address _interestRateModel) {
        require(
            _collateralToken != address(0) && _debtToken != address(0) && _oracle != address(0)
                && _interestRateModel != address(0),
            ZeroAddress()
        );

        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        oracle = IPriceOracle(_oracle);
        interestRateModel = InterestRateModel(_interestRateModel);

        collateralTokenDecimals = IERC20Metadata(_collateralToken).decimals();
        debtTokenDecimals = IERC20Metadata(address(_debtToken)).decimals();

        borrowIndex = 1e18;
        lastInterestUpdate = block.timestamp;
    }

    function supplyCollateral(uint256 amount) external {
        require(amount > 0, ZeroAmount());

        TokenTransfer.pullExact(collateralToken, msg.sender, amount);

        _collateralBalance[msg.sender] += amount;

        emit Supplied(msg.sender, address(collateralToken), amount);
    }

    function collateralOf(address user) external view returns (uint256) {
        return _collateralBalance[user];
    }

    function borrow(uint256 amount) external {
        require(amount > 0, ZeroAmount());

        // new borrow should not get historical interest for past interval
        _accrueInterest();

        // read current actual debt using stored updated index
        uint256 currentDebt = _scaledDebtToActual(_scaledDebt[msg.sender]);

        uint256 debtAfter = currentDebt + amount;

        uint256 maxDebt = maxBorrow(msg.sender);

        // actual debt used for risk checks. check debtAfter against LTV
        require(debtAfter <= maxDebt, BorrowCapacityExceeded(debtAfter, maxDebt));

        // convert new amount to scaled delta
        uint256 scaledBorrowAmount = _actualDebtToScaledBorrow(amount);
        // scaled debt used for storage. increase user scaled debt
        _scaledDebt[msg.sender] += scaledBorrowAmount;
        // increase totalScaledDebt
        totalScaledDebt += scaledBorrowAmount;

        TokenTransfer.pushExact(debtToken, msg.sender, amount);

        emit Borrowed(msg.sender, address(debtToken), amount);
    }

    // Returns collateral value in oracle quote currency, normalized to WAD.
    function collateralValue(address user) public view returns (uint256 valueWad) {
        uint256 userCollateralAmount = _collateralBalance[user];

        (uint256 price,) = oracle.latestPrice();

        valueWad = DecimalMath.valueInWad(
            userCollateralAmount, collateralTokenDecimals, price, DecimalMath.WAD_DECIMALS, Math.Rounding.Trunc
        );
    }

    // Returns maximum borrow capacity in debt-token native units.
    function maxBorrow(address user) public view returns (uint256 maxDebtAmount) {
        uint256 maxBorrowValueWad = Math.mulDiv(collateralValue(user), LTV, BPS, Math.Rounding.Trunc);

        return maxDebtAmount =
            DecimalMath.scale(maxBorrowValueWad, DecimalMath.WAD_DECIMALS, debtTokenDecimals, Math.Rounding.Trunc);
    }

    function availableToBorrow(address user) public view returns (uint256) {
        uint256 maxBorrowCapacity = maxBorrow(user);
        uint256 existingDebt = debtOf(user);

        // Existing debt can legitimately exceed current LTV capacity after market movement without immediately
        // exceeding liquidation threshold.
        if (existingDebt >= maxBorrowCapacity) return 0;

        return maxBorrowCapacity - existingDebt;
    }

    function debtOf(address user) public view returns (uint256) {
        return _scaledDebtToActual(_scaledDebt[user]);
    }

    function healthFactor(address user) public view returns (uint256 hf) {
        uint256 debt = debtOf(user);

        if (debt == 0) return type(uint256).max;

        uint256 debtValueWad =
            DecimalMath.scale(debt, debtTokenDecimals, uint8(DecimalMath.WAD_DECIMALS), Math.Rounding.Ceil);

        uint256 collateralValueWad = collateralValue(user);

        uint256 adjustedCollateralWad = Math.mulDiv(collateralValueWad, LIQUIDATION_THRESHOLD, BPS, Math.Rounding.Floor);

        return hf = DecimalMath.ratioWad(adjustedCollateralWad, debtValueWad, Math.Rounding.Trunc);
    }

    function withdrawCollateral(uint256 amount) external {
        require(amount > 0, ZeroAmount());

        uint256 collateralBefore = _collateralBalance[msg.sender];

        require(amount <= collateralBefore, InsufficientCollateral(amount, collateralBefore));

        _collateralBalance[msg.sender] = collateralBefore - amount;

        uint256 hf = healthFactor(msg.sender);

        require(hf >= 1e18, UnhealthyPosition(hf));

        TokenTransfer.pushExact(collateralToken, msg.sender, amount);

        emit Withdrawn(msg.sender, address(collateralToken), amount);
    }

    function repay(uint256 amount) external {
        require(amount > 0, ZeroAmount());

        _accrueInterest();

        uint256 currentDebt = _scaledDebtToActual(_scaledDebt[msg.sender]);

        require(amount <= currentDebt, CurrentDebtExceeded(amount, currentDebt));

        TokenTransfer.pullExact(debtToken, msg.sender, amount);

        uint256 userScaledDebt = _scaledDebt[msg.sender];

        if (amount == currentDebt) {
            _scaledDebt[msg.sender] = 0;

            totalScaledDebt -= userScaledDebt;
        } else {
            uint256 scaledRepayAmount = _actualDebtToScaledRepay(amount);

            require(scaledRepayAmount > 0, DebtReductionTooSmall(amount));

            _scaledDebt[msg.sender] = userScaledDebt - scaledRepayAmount;

            totalScaledDebt -= scaledRepayAmount;
        }

        emit Repaid(msg.sender, address(debtToken), amount);
    }

    function maxLiquidatableDebt(address borrower) public view returns (uint256) {
        require(borrower != address(0), ZeroAddress());

        uint256 currentDebt = debtOf(borrower);

        return Math.mulDiv(currentDebt, CLOSE_FACTOR, BPS, Math.Rounding.Trunc);
    }

    function collateralToSeize(uint256 debtToRepay) public view returns (uint256 collateralAmount) {
        require(debtToRepay > 0, ZeroAmount());

        uint256 debtValueWad =
            DecimalMath.scale(debtToRepay, debtTokenDecimals, DecimalMath.WAD_DECIMALS, Math.Rounding.Ceil);

        uint256 seizeValueWad = Math.mulDiv(debtValueWad, BPS + LIQUIDATION_BONUS, BPS, Math.Rounding.Trunc);

        (uint256 priceWad,) = oracle.latestPrice();

        return collateralAmount = Math.mulDiv(
                seizeValueWad, 10 ** collateralTokenDecimals, priceWad, Math.Rounding.Floor
            );
    }

    // borrower must be unhealthy
    //     ↓
    // debtToRepay <= maxLiquidatableDebt
    //         ↓
    // calculate collateralToSeize
    //         ↓
    // cannot seize more than borrower actually owns
    //         ↓
    // pull debt from liquidator
    //         ↓
    // reduce borrower debt
    //         ↓
    // reduce borrower collateral
    //         ↓
    // send collateral to liquidator

    function liquidate(address borrower, uint256 debtToRepay) external {
        require(borrower != address(0), ZeroAddress());
        require(debtToRepay > 0, ZeroAmount());

        _accrueInterest();

        uint256 hf = healthFactor(borrower);
        require(hf < 1e18, PositionNotLiquidatable(hf));

        uint256 maxLiqDebt = maxLiquidatableDebt(borrower);
        require(debtToRepay <= maxLiqDebt, DebtToRepayExceedsMaxLiquidatableDebt(debtToRepay, maxLiqDebt));

        uint256 collateralAmountToSeize = collateralToSeize(debtToRepay);
        uint256 currentCollateral = _collateralBalance[borrower];

        require(
            collateralAmountToSeize <= currentCollateral,
            SeizeMoreThanBorrowerOwns(collateralAmountToSeize, currentCollateral)
        );

        TokenTransfer.pullExact(debtToken, msg.sender, debtToRepay);

        uint256 borrowerScaledDebt = _scaledDebt[borrower];

        uint256 scaledDeptToRepay = _actualDebtToScaledRepay(debtToRepay);

        require(scaledDeptToRepay != 0, DebtReductionTooSmall(debtToRepay));

        _scaledDebt[borrower] = borrowerScaledDebt - scaledDeptToRepay;

        totalScaledDebt -= scaledDeptToRepay;

        _collateralBalance[borrower] = currentCollateral - collateralAmountToSeize;

        TokenTransfer.pushExact(collateralToken, msg.sender, collateralAmountToSeize);

        emit Liquidated(msg.sender, borrower, debtToRepay, collateralAmountToSeize);
    }

    function totalDebt() public view returns (uint256) {
        return Math.mulDiv(totalScaledDebt, currentBorrowIndex(), 1e18, Math.Rounding.Ceil);
    }

    function utilization() public view returns (uint256) {
        uint256 availableLiquidity = debtToken.balanceOf(address(this));
        uint256 currentTotalDebt = totalDebt();

        return interestRateModel.utilization(availableLiquidity, currentTotalDebt);
    }

    function currentBorrowRate() public view returns (uint256) {
        uint256 currentUtilization = utilization();

        return interestRateModel.borrowRate(currentUtilization);
    }

    function accrueInterest() external {
        _accrueInterest();
    }

    // Returns the borrow index as of the current timestamp without mutating storage.
    //
    // Interest for the elapsed interval is calculated from the last committed
    // reserve state (`borrowIndex` + `totalScaledDebt`). This avoids the circular
    // dependency:
    //
    // current index -> current debt -> utilization -> rate -> current index.
    //
    // `_accrueInterest()` later commits this previewed value to storage.
    function currentBorrowIndex() public view returns (uint256) {
        uint256 currentTimestamp = block.timestamp;
        if (currentTimestamp == lastInterestUpdate) return borrowIndex;

        uint256 storedUtilization = _storedUtilization();
        uint256 intervalBorrowRate = interestRateModel.borrowRate(storedUtilization);

        return _previewBorrowIndex(intervalBorrowRate, currentTimestamp);
    }

    function _previewBorrowIndex(uint256 annualRateWad, uint256 timestamp) internal view returns (uint256) {
        require(timestamp >= lastInterestUpdate, InvalidTimestamp(timestamp, lastInterestUpdate));

        uint256 elapsed = timestamp - lastInterestUpdate;

        if (elapsed == 0 || annualRateWad == 0) return borrowIndex;

        // newIndex = oldIndex + oldIndex × rate × elapsed / YEAR

        uint256 growth = Math.mulDiv(borrowIndex, annualRateWad, 1e18, Math.Rounding.Ceil);

        growth = Math.mulDiv(growth, elapsed, SECONDS_PER_YEAR, Math.Rounding.Ceil);

        return borrowIndex + growth;
    }

    function _accrueInterest() internal {
        uint256 currentTimestamp = block.timestamp;
        if (currentTimestamp == lastInterestUpdate) return;

        // The elapsed interval accrues using utilization from the last
        // committed reserve state, not the virtually accrued current state.
        uint256 storedUtilization = _storedUtilization();
        uint256 currentRate = interestRateModel.borrowRate(storedUtilization);
        uint256 newIndex = _previewBorrowIndex(currentRate, currentTimestamp);

        borrowIndex = newIndex;
        lastInterestUpdate = currentTimestamp;
    }

    function _totalDebtAtStoredIndex() internal view returns (uint256) {
        return Math.mulDiv(totalScaledDebt, borrowIndex, 1e18, Math.Rounding.Ceil);
    }

    // Utilization based on the last committed borrow index.
    // Used only to determine the rate for the elapsed accrual interval.
    function _storedUtilization() internal view returns (uint256) {
        uint256 availableLiquidity = debtToken.balanceOf(address(this));

        uint256 storedDebt = _totalDebtAtStoredIndex();

        return interestRateModel.utilization(availableLiquidity, storedDebt);
    }

    function _scaledDebtToActual(uint256 scaledDebt) internal view returns (uint256) {
        uint256 actualBorrowIndex = currentBorrowIndex();

        require(actualBorrowIndex >= 1e18, InvalidIndex(actualBorrowIndex));

        return Math.mulDiv(scaledDebt, actualBorrowIndex, 1e18, Math.Rounding.Ceil);
    }

    function _actualDebtToScaledBorrow(uint256 borrowAmount) internal view returns (uint256) {
        uint256 actualBorrowIndex = currentBorrowIndex();

        require(actualBorrowIndex >= 1e18, InvalidIndex(actualBorrowIndex));

        return Math.mulDiv(borrowAmount, 1e18, actualBorrowIndex, Math.Rounding.Ceil);
    }

    function _actualDebtToScaledRepay(uint256 repayAmount) internal view returns (uint256) {
        uint256 actualBorrowIndex = currentBorrowIndex();

        require(actualBorrowIndex >= 1e18, InvalidIndex(actualBorrowIndex));

        return Math.mulDiv(repayAmount, 1e18, actualBorrowIndex, Math.Rounding.Floor);
    }
}
