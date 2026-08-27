// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IPriceOracle } from "src/labs/oracles/interfaces/IPriceOracle.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";
import { TokenTransfer, IERC20 } from "src/common/token/TokenTransfer.sol";

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

    uint256 private constant BPS = 10_000;

    uint8 public immutable collateralTokenDecimals;
    uint8 public immutable debtTokenDecimals;

    mapping(address user => uint256 amount) private _collateralBalance;
    mapping(address user => uint256 amount) private _debtBalance;

    constructor(address _collateralToken, address _debtToken, address _oracle) {
        require(_collateralToken != address(0) && _debtToken != address(0) && _oracle != address(0), ZeroAddress());

        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        oracle = IPriceOracle(_oracle);

        collateralTokenDecimals = IERC20Metadata(_collateralToken).decimals();
        debtTokenDecimals = IERC20Metadata(address(_debtToken)).decimals();
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

        uint256 debtAfter = _debtBalance[msg.sender] + amount;

        uint256 maxDebt = maxBorrow(msg.sender);

        require(debtAfter <= maxDebt, BorrowCapacityExceeded(debtAfter, maxDebt));

        _debtBalance[msg.sender] = debtAfter;

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
        uint256 existingDebt = _debtBalance[user];

        // Existing debt can legitimately exceed current LTV capacity after market movement without immediately
        // exceeding liquidation threshold.
        if (existingDebt >= maxBorrowCapacity) return 0;

        return maxBorrowCapacity - existingDebt;
    }

    function debtOf(address user) external view returns (uint256) {
        return _debtBalance[user];
    }

    function healthFactor(address user) public view returns (uint256 hf) {
        uint256 debt = _debtBalance[user];

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

        uint256 currentDebt = _debtBalance[msg.sender];

        require(amount <= currentDebt, CurrentDebtExceeded(amount, currentDebt));

        TokenTransfer.pullExact(debtToken, msg.sender, amount);

        _debtBalance[msg.sender] = currentDebt - amount;

        emit Repaid(msg.sender, address(debtToken), amount);
    }

    function maxLiquidatableDebt(address borrower) public view returns (uint256) {
        require(borrower != address(0), ZeroAddress());

        uint256 currentDebt = _debtBalance[borrower];

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

        _debtBalance[borrower] -= debtToRepay;
        _collateralBalance[borrower] = currentCollateral - collateralAmountToSeize;

        TokenTransfer.pushExact(collateralToken, msg.sender, collateralAmountToSeize);

        emit Liquidated(msg.sender, borrower, debtToRepay, collateralAmountToSeize);
    }
}
