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

    event Supplied(address indexed user, address indexed collateralToken, uint256 amount);
    event Borrowed(address indexed user, address indexed debtToken, uint256 amount);

    IERC20 public immutable collateralToken; // WETH
    IERC20 public immutable debtToken; // USDC

    IPriceOracle public immutable oracle;

    uint256 public constant LTV = 7500; // 75%
    uint256 public constant LIQUIDATION_THRESHOLD = 8000; // 80%

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
}
