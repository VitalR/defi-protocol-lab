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

    event Supplied(address indexed caller, address indexed onBehalfOf, uint256 actualAmount, uint256 scaledAmount);
    event Withdrawn(address indexed user, address indexed to, uint256 actualAmount, uint256 scaledAmount);

    IERC20Metadata public immutable UNDERLYING;

    ScaledSupplyToken public immutable SUPPLY_TOKEN;
    ScaledDebtToken public immutable DEBT_TOKEN;

    uint256 internal _liquidityIndex = DecimalMath.WAD;
    uint256 internal _borrowIndex = DecimalMath.WAD;

    uint256 public availableLiquidity;

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
    }

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

        uint256 index = _liquidityIndex;

        uint256 scaledAmount = Math.mulDiv(amount, DecimalMath.WAD, index, Math.Rounding.Floor);

        require(scaledAmount > 0, SupplyTooSmall(amount));

        UNDERLYING.pullExact(msg.sender, amount);

        availableLiquidity += amount;

        SUPPLY_TOKEN.mintScaled(onBehalfOf, scaledAmount);

        emit Supplied(msg.sender, onBehalfOf, amount, scaledAmount);
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

        uint256 userSupply = SUPPLY_TOKEN.balanceOf(msg.sender);

        require(amount <= userSupply, WithdrawExceedsSupply(amount, userSupply));

        require(amount <= availableLiquidity, InsufficientLiquidity(amount, availableLiquidity));

        uint256 scaledAmount;

        if (amount == userSupply) {
            // Full withdrawal must remove all scaled dust.
            scaledAmount = SUPPLY_TOKEN.scaledBalanceOf(msg.sender);
        } else {
            scaledAmount = Math.mulDiv(amount, DecimalMath.WAD, _liquidityIndex, Math.Rounding.Ceil);
        }

        availableLiquidity -= amount;

        SUPPLY_TOKEN.burnScaled(msg.sender, scaledAmount);

        UNDERLYING.pushExact(to, amount);

        emit Withdrawn(msg.sender, to, amount, scaledAmount);

        withdrawnAmount = amount;
    }

    function currentLiquidityIndex() external view override returns (uint256) {
        return _liquidityIndex;
    }

    function currentBorrowIndex() external view override returns (uint256) {
        return _borrowIndex;
    }
}
