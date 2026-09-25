// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IBorrowIndexProvider } from "src/labs/lending/interfaces/IBorrowIndexProvider.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";

contract ScaledDebtToken is IERC20Metadata {
    error ZeroAddress();
    error ZeroScaledAmount();
    error OnlyPool(address caller);
    error OperationNotSupported();
    error ScaledDebtExceeded(address user, uint256 requested, uint256 available);
    error InvalidBorrowIndex(uint256 index);

    event MintScaled(address indexed user, uint256 actualAmount, uint256 scaledAmount, uint256 index);
    event BurnScaled(address indexed user, uint256 actualAmount, uint256 scaledAmount, uint256 index);

    address public immutable POOL;

    uint256 internal _scaledTotalDebt;

    string internal _name;
    string internal _symbol;
    uint8 internal immutable _decimals;

    mapping(address user => uint256 scaledDebt) internal _scaledDebt;

    modifier onlyPool() {
        require(msg.sender == POOL, OnlyPool(msg.sender));
        _;
    }

    constructor(address pool, string memory name_, string memory symbol_, uint8 decimals_) {
        require(pool != address(0), ZeroAddress());

        POOL = pool;

        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function mintScaled(address user, uint256 scaledAmount) external onlyPool returns (bool firstBorrow) {
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
        index = IBorrowIndexProvider(POOL).currentBorrowIndex();

        require(index >= DecimalMath.WAD, InvalidBorrowIndex(index));
    }

    function _scaledToActual(uint256 scaledAmount, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(scaledAmount, index, DecimalMath.WAD, Math.Rounding.Ceil);
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
