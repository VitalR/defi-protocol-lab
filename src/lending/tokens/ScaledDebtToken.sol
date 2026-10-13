// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IIndexProvider } from "src/lending/interfaces/IIndexProvider.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";

contract ScaledDebtToken is IERC20Metadata {
    error ZeroAddress();
    error ZeroAmount();
    error ZeroScaledAmount();
    error OnlyPool(address caller);
    error OperationNotSupported();
    error ScaledDebtExceeded(address user, uint256 requested, uint256 available);
    error InvalidBorrowIndex(uint256 index);
    error InsufficientBorrowAllowance(address delegator, address delegatee, uint256 requested, uint256 available);

    event MintScaled(address indexed user, uint256 actualAmount, uint256 scaledAmount, uint256 index);
    event BurnScaled(address indexed user, uint256 actualAmount, uint256 scaledAmount, uint256 index);
    event BorrowAllowanceDelegated(
        address indexed delegator, address indexed delegatee, address indexed asset, uint256 amount
    );

    address public immutable POOL;
    address public immutable UNDERLYING;

    uint256 internal _scaledTotalDebt;

    string internal _name;
    string internal _symbol;
    uint8 internal immutable _decimals;

    mapping(address user => uint256 scaledDebt) internal _scaledDebt;

    // Amounts are denominated in underlying token units.
    mapping(address delegator => mapping(address delegatee => uint256 amount)) internal _borrowAllowances;

    modifier onlyPool() {
        require(msg.sender == POOL, OnlyPool(msg.sender));
        _;
    }

    constructor(address pool, address underlying, string memory name_, string memory symbol_, uint8 decimals_) {
        require(pool != address(0) && underlying != address(0), ZeroAddress());

        POOL = pool;
        UNDERLYING = underlying;

        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function mintScaled(address user, uint256 scaledAmount) external onlyPool returns (bool firstBorrow) {
        return _mintScaled(user, scaledAmount);
    }

    function burnScaled(address user, uint256 scaledAmount) external onlyPool returns (bool zeroBalanceAfter) {
        require(user != address(0), ZeroAddress());
        require(scaledAmount > 0, ZeroScaledAmount());

        uint256 userScaledDebt = _scaledDebt[user];

        require(scaledAmount <= userScaledDebt, ScaledDebtExceeded(user, scaledAmount, userScaledDebt));

        uint256 index = _currentBorrowIndex();
        uint256 actualDebtBefore = _scaledToActual(userScaledDebt, index);

        uint256 remainingScaledDebt;

        unchecked {
            remainingScaledDebt = userScaledDebt - scaledAmount;

            _scaledDebt[user] = remainingScaledDebt;
            _scaledTotalDebt -= scaledAmount;
        }

        uint256 actualDebtAfter = _scaledToActual(remainingScaledDebt, index);

        uint256 actualBurned = actualDebtBefore - actualDebtAfter;

        zeroBalanceAfter = remainingScaledDebt == 0;

        emit Transfer(user, address(0), actualBurned);
        emit BurnScaled(user, actualBurned, scaledAmount, index);
    }

    function mintBorrow(address caller, address onBehalfOf, uint256 amount, uint256 scaledAmount)
        external
        onlyPool
        returns (bool firstBorrow)
    {
        require(caller != address(0) && onBehalfOf != address(0), ZeroAddress());
        require(amount > 0, ZeroAmount());
        require(scaledAmount > 0, ZeroScaledAmount());

        if (caller != onBehalfOf) {
            uint256 allowed = _borrowAllowances[onBehalfOf][caller];

            require(amount <= allowed, InsufficientBorrowAllowance(onBehalfOf, caller, amount, allowed));

            // Maximum allowance represents unlimited delegation.
            if (allowed != type(uint256).max) {
                uint256 remaining = allowed - amount;

                _borrowAllowances[onBehalfOf][caller] = remaining;

                emit BorrowAllowanceDelegated(onBehalfOf, caller, UNDERLYING, remaining);
            }
        }

        return _mintScaled(onBehalfOf, scaledAmount);
    }

    function approveDelegation(address delegatee, uint256 amount) external {
        require(delegatee != address(0), ZeroAddress());

        _borrowAllowances[msg.sender][delegatee] = amount;

        emit BorrowAllowanceDelegated(msg.sender, delegatee, UNDERLYING, amount);
    }

    function borrowAllowance(address delegator, address delegatee) external view returns (uint256) {
        return _borrowAllowances[delegator][delegatee];
    }

    function scaledBalanceOf(address user) external view returns (uint256) {
        return _scaledDebt[user];
    }

    function scaledTotalSupply() external view returns (uint256) {
        return _scaledTotalDebt;
    }

    function balanceOf(address user) public view override returns (uint256) {
        uint256 index = _currentBorrowIndex();

        return Math.mulDiv(_scaledDebt[user], index, DecimalMath.WAD, Math.Rounding.Ceil);
    }

    function totalSupply() public view override returns (uint256) {
        uint256 index = _currentBorrowIndex();

        return Math.mulDiv(_scaledTotalDebt, index, DecimalMath.WAD, Math.Rounding.Ceil);
    }

    function approve(address, uint256) external pure override returns (bool) {
        revert OperationNotSupported();
    }

    function allowance(address, address) external pure override returns (uint256) {
        revert OperationNotSupported();
    }

    function transfer(address, uint256) external pure override returns (bool) {
        revert OperationNotSupported();
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        revert OperationNotSupported();
    }

    function _currentBorrowIndex() internal view returns (uint256 index) {
        index = IIndexProvider(POOL).currentBorrowIndex(UNDERLYING);

        require(index >= DecimalMath.WAD, InvalidBorrowIndex(index));
    }

    function _scaledToActual(uint256 scaledAmount, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(scaledAmount, index, DecimalMath.WAD, Math.Rounding.Ceil);
    }

    function _mintScaled(address user, uint256 scaledAmount) internal returns (bool firstBorrow) {
        require(user != address(0), ZeroAddress());
        require(scaledAmount > 0, ZeroScaledAmount());

        uint256 userScaledDebt = _scaledDebt[user];

        firstBorrow = userScaledDebt == 0;

        uint256 index = _currentBorrowIndex();
        uint256 actualDebtBefore = _scaledToActual(userScaledDebt, index);

        uint256 newScaledDebt = userScaledDebt + scaledAmount;

        _scaledDebt[user] = newScaledDebt;
        _scaledTotalDebt += scaledAmount;

        uint256 actualDebtAfter = _scaledToActual(newScaledDebt, index);

        uint256 actualMinted = actualDebtAfter - actualDebtBefore;

        emit Transfer(address(0), user, actualMinted);
        emit MintScaled(user, actualMinted, scaledAmount, index);
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }
}
