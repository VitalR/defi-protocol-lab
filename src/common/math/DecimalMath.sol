// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

// Token decimals are not quantities that should be divided by each other. They describe powers of ten used to interpret
// the stored integer.
library DecimalMath {
    uint8 internal constant WAD_DECIMALS = 18;
    uint256 internal constant WAD = 1e18;

    error UnsupportedDecimals(uint8 decimals);
    error ZeroDenominator();

    // Change decimal representation without changing economic value.
    function scale(uint256 _amount, uint8 _fromDecimals, uint8 _toDecimals, Math.Rounding _rounding)
        internal
        pure
        returns (uint256)
    {
        if (_fromDecimals > WAD_DECIMALS) revert UnsupportedDecimals(_fromDecimals);
        if (_toDecimals > WAD_DECIMALS) revert UnsupportedDecimals(_toDecimals);

        if (_fromDecimals == _toDecimals) return _amount;

        uint256 factor;
        if (_fromDecimals < _toDecimals) {
            factor = 10 ** (_toDecimals - _fromDecimals);

            // Scaling up is exact. Rounding is irrelevant.
            return _amount * factor;
        }

        factor = 10 ** (_fromDecimals - _toDecimals);

        // Scaling down may lose precision, so rounding matters.
        return Math.mulDiv(_amount, 1, factor, _rounding);
    }

    // Convert token amount × price into an 18-decimal quote value.
    function valueInWad(
        uint256 _amount,
        uint8 _amountDecimals,
        uint256 _price,
        uint8 _priceDecimals,
        Math.Rounding _rounding
    ) internal pure returns (uint256) {
        if (_amountDecimals > WAD_DECIMALS) revert UnsupportedDecimals(_amountDecimals);

        uint256 normalizedPrice = scale(_price, _priceDecimals, WAD_DECIMALS, _rounding);

        return Math.mulDiv(_amount, normalizedPrice, 10 ** _amountDecimals, _rounding);
    }

    // Divide two comparable values while preserving 18-decimal precision.
    function ratioWad(uint256 _numerator, uint256 _denominator, Math.Rounding _rounding)
        internal
        pure
        returns (uint256)
    {
        require(_denominator != 0, ZeroDenominator());
        return Math.mulDiv(_numerator, WAD, _denominator, _rounding);
    }
}
