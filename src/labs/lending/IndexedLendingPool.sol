// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { DecimalMath } from "src/common/math/DecimalMath.sol";
import { ILiquidityIndexProvider } from "src/labs/lending/interfaces/ILiquidityIndexProvider.sol";
import { IBorrowIndexProvider } from "src/labs/lending/interfaces/IBorrowIndexProvider.sol";
import { ScaledSupplyToken } from "src/labs/lending/tokens/ScaledSupplyToken.sol";
import { ScaledDebtToken } from "src/labs/lending/tokens/ScaledDebtToken.sol";

contract IndexedLendingPool is ILiquidityIndexProvider, IBorrowIndexProvider {
    error ZeroAddress();
    error InvalidUnderlying(address underlying);

    IERC20Metadata public immutable UNDERLYING;

    ScaledSupplyToken public immutable SUPPLY_TOKEN;
    ScaledDebtToken public immutable DEBT_TOKEN;

    uint256 internal _liquidityIndex = DecimalMath.WAD;
    uint256 internal _borrowIndex = DecimalMath.WAD;

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

    function currentLiquidityIndex() external view override returns (uint256) {
        return _liquidityIndex;
    }

    function currentBorrowIndex() external view override returns (uint256) {
        return _borrowIndex;
    }
}
