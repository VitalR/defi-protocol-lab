// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";

library LiquidationMath {
    error InvalidPrice();
    error InvalidLiquidationBonus();
    error UnsupportedDecimals();
    error LiquidationTooSmall();

    struct QuoteParams {
        uint256 debtBudget;
        uint256 collateralBalance;
        uint256 debtPriceWad;
        uint256 collateralPriceWad;
        uint256 liquidationBonusWad;
        uint8 debtDecimals;
        uint8 collateralDecimals;
    }

    function calculateAmounts(QuoteParams memory p)
        internal
        pure
        returns (uint256 debtRepaid, uint256 collateralSeized)
    {
        require(p.debtPriceWad > 0 && p.collateralPriceWad > 0, InvalidPrice());
        require(p.liquidationBonusWad > DecimalMath.WAD, InvalidLiquidationBonus());
        require(p.debtDecimals <= 18 && p.collateralDecimals <= 18, UnsupportedDecimals());

        debtRepaid = p.debtBudget;
        collateralSeized = _collateralForDebt(p, debtRepaid);

        if (collateralSeized > p.collateralBalance) {
            // Convert available collateral into a supported debt budget.
            uint256 collateralValueWad = Math.mulDiv(
                p.collateralBalance, p.collateralPriceWad, 10 ** uint256(p.collateralDecimals), Math.Rounding.Floor
            );

            uint256 supportedDebtValueWad =
                Math.mulDiv(collateralValueWad, DecimalMath.WAD, p.liquidationBonusWad, Math.Rounding.Floor);

            uint256 supportedDebtAmount = Math.mulDiv(
                supportedDebtValueWad, 10 ** uint256(p.debtDecimals), p.debtPriceWad, Math.Rounding.Floor
            );

            debtRepaid = Math.min(debtRepaid, supportedDebtAmount);

            // Quote again for the reduced payment.
            collateralSeized = _collateralForDebt(p, debtRepaid);
        }

        require(debtRepaid > 0 && collateralSeized > 0, LiquidationTooSmall());
    }

    function _collateralForDebt(QuoteParams memory p, uint256 debtAmount) private pure returns (uint256) {
        uint256 debtValueWad =
            Math.mulDiv(debtAmount, p.debtPriceWad, 10 ** uint256(p.debtDecimals), Math.Rounding.Floor);

        uint256 collateralValueWad =
            Math.mulDiv(debtValueWad, p.liquidationBonusWad, DecimalMath.WAD, Math.Rounding.Floor);

        return Math.mulDiv(
            collateralValueWad, 10 ** uint256(p.collateralDecimals), p.collateralPriceWad, Math.Rounding.Floor
        );
    }
}
