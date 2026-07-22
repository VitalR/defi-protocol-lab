// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { OracleValuation } from "src/labs/oracles/OracleValuation.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";

contract OracleValuationHarness {
    function valueInWad(uint256 amount, uint8 tokenDecimals, uint256 priceWad, Math.Rounding rounding)
        public
        pure
        returns (uint256)
    {
        return OracleValuation.valueInWad(amount, tokenDecimals, priceWad, rounding);
    }

    function amountFromValueWad(uint256 valueWad, uint8 tokenDecimals, uint256 priceWad, Math.Rounding rounding)
        public
        pure
        returns (uint256)
    {
        return OracleValuation.amountFromValueWad(valueWad, tokenDecimals, priceWad, rounding);
    }
}
