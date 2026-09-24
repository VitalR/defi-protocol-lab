// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { ILiquidityIndexProvider } from "src/labs/lending/interfaces/ILiquidityIndexProvider.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";

contract ScaledSupplyToken is IERC20Metadata {
    error ZeroAddress();
    error ZeroScaledAmount();
    error OnlyPool(address caller);
    error ScaledBalanceExceeded(address user, uint256 requested, uint256 available);
    error OperationNotSupported();
    error InvalidRecipient(address recipient);
    error InvalidSpender(address spender);
    error InsufficientAllowance(address spender, uint256 requested, uint256 available);
    error InvalidLiquidityIndex(uint256 index);

    event MintScaled(address indexed user, uint256 actualAmount, uint256 scaledAmount, uint256 index);
    event BurnScaled(address indexed user, uint256 actualAmount, uint256 scaledAmount, uint256 index);
    event BalanceTransfer(address indexed from, address indexed to, uint256 scaledAmount, uint256 index);

    address public immutable POOL;

    uint256 internal _scaledTotalSupply;

    string internal _name;
    string internal _symbol;
    uint8 internal immutable _decimals;

    mapping(address user => uint256 scaledBalances) internal _scaledBalances;

    mapping(address owner => mapping(address spender => uint256 amount)) _allowances;

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

    function mintScaled(address user, uint256 scaledAmount) external onlyPool returns (bool firstSupply) {
        require(user != address(0), ZeroAddress());
        require(scaledAmount > 0, ZeroScaledAmount());

        firstSupply = _scaledBalances[user] == 0;

        uint256 index = _currentLiquidityIndex();

        uint256 actualBalanceBefore = _scaledToActual(_scaledBalances[user], index);

        _scaledBalances[user] += scaledAmount;
        _scaledTotalSupply += scaledAmount;

        uint256 actualBalanceAfter = _scaledToActual(_scaledBalances[user], index);

        uint256 actualMinted = actualBalanceAfter - actualBalanceBefore;

        emit Transfer(address(0), user, actualMinted);

        emit MintScaled(user, actualMinted, scaledAmount, index);
    }

    function burnScaled(address user, uint256 scaledAmount) external onlyPool returns (bool zeroBalanceAfter) {
        require(user != address(0), ZeroAddress());
        require(scaledAmount > 0, ZeroScaledAmount());

        uint256 userBalance = _scaledBalances[user];

        require(scaledAmount <= userBalance, ScaledBalanceExceeded(user, scaledAmount, userBalance));

        uint256 index = _currentLiquidityIndex();
        uint256 actualBalanceBefore = _scaledToActual(_scaledBalances[user], index);

        unchecked {
            _scaledBalances[user] -= scaledAmount;
            _scaledTotalSupply -= scaledAmount;
        }

        uint256 actualBalanceAfter = _scaledToActual(_scaledBalances[user], index);

        uint256 actualBurned = actualBalanceBefore - actualBalanceAfter;

        zeroBalanceAfter = _scaledBalances[user] == 0;

        emit Transfer(user, address(0), actualBurned);

        emit BurnScaled(user, actualBurned, scaledAmount, index);
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transferActual(msg.sender, to, amount);

        return true;
    }

    function _transferActual(address from, address to, uint256 actualAmount) internal {
        require(to != address(0), InvalidRecipient(to));

        uint256 index = _currentLiquidityIndex();

        uint256 scaledAmount = _actualToScaledTransfer(actualAmount, index);

        uint256 senderScaledBalance = _scaledBalances[from];

        require(scaledAmount <= senderScaledBalance, ScaledBalanceExceeded(from, scaledAmount, senderScaledBalance));

        if (from != to && actualAmount > 0) {
            unchecked {
                _scaledBalances[from] = senderScaledBalance - scaledAmount;

                _scaledBalances[to] += scaledAmount;
            }
        }

        emit Transfer(from, to, actualAmount);

        emit BalanceTransfer(from, to, scaledAmount, index);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        require(spender != address(0), InvalidSpender(spender));

        _allowances[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transferActual(from, to, amount);

        return true;
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 currentAllowance = _allowances[owner][spender];

        if (currentAllowance == type(uint256).max) return;

        require(amount <= currentAllowance, InsufficientAllowance(spender, amount, currentAllowance));

        unchecked {
            _allowances[owner][spender] = currentAllowance - amount;
        }

        emit Approval(owner, spender, currentAllowance - amount);
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function scaledBalanceOf(address user) external view returns (uint256) {
        return _scaledBalances[user];
    }

    function scaledTotalSupply() external view returns (uint256) {
        return _scaledTotalSupply;
    }

    function balanceOf(address user) public view override returns (uint256) {
        uint256 index = _currentLiquidityIndex();

        return Math.mulDiv(_scaledBalances[user], index, DecimalMath.WAD, Math.Rounding.Floor);
    }

    function totalSupply() public view override returns (uint256) {
        uint256 index = _currentLiquidityIndex();

        return Math.mulDiv(_scaledTotalSupply, index, DecimalMath.WAD, Math.Rounding.Floor);
    }

    function _currentLiquidityIndex() internal view returns (uint256 index) {
        index = ILiquidityIndexProvider(POOL).currentLiquidityIndex();

        require(index > 0, InvalidLiquidityIndex(index));
    }

    function _scaledToActual(uint256 scaledAmount, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(scaledAmount, index, DecimalMath.WAD, Math.Rounding.Floor);
    }

    function _actualToScaledTransfer(uint256 actualAmount, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(actualAmount, DecimalMath.WAD, index, Math.Rounding.Ceil);
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
