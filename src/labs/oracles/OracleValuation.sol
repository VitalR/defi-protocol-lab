// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";

library OracleValuation {
    error UnsupportedTokenDecimals(uint8 decimals);
    error ZeroPrice();

    function valueInWad(uint256 amount, uint8 tokenDecimals, uint256 priceWad, Math.Rounding rounding)
        internal
        pure
        returns (uint256 valueWad)
    {
        if (tokenDecimals > DecimalMath.WAD_DECIMALS) revert UnsupportedTokenDecimals(tokenDecimals);
        require(priceWad > 0, ZeroPrice());

        // valueWad = amount × priceWad / 10^tokenDecimals
        valueWad = DecimalMath.valueInWad(amount, tokenDecimals, priceWad, DecimalMath.WAD_DECIMALS, rounding);
    }

    function amountFromValueWad(uint256 valueWad, uint8 tokenDecimals, uint256 priceWad, Math.Rounding rounding)
        internal
        pure
        returns (uint256 amount)
    {
        if (tokenDecimals > DecimalMath.WAD_DECIMALS) revert UnsupportedTokenDecimals(tokenDecimals);
        require(priceWad > 0, ZeroPrice());

        // amount = valueWad × 10^tokenDecimals / priceWad
        amount = Math.mulDiv(valueWad, 10 ** tokenDecimals, priceWad, rounding);
    }
}
