// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { DecimalMath } from "src/common/math/DecimalMath.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract DecimalMathHarness {
    function scale(uint256 _amount, uint8 _fromDecimals, uint8 _toDecimals, Math.Rounding _rounding)
        external
        pure
        returns (uint256)
    {
        return DecimalMath.scale(_amount, _fromDecimals, _toDecimals, _rounding);
    }

    function valueInWad(
        uint256 _amount,
        uint8 _amountDecimals,
        uint256 _price,
        uint8 _priceDecimals,
        Math.Rounding _rounding
    ) external pure returns (uint256) {
        return DecimalMath.valueInWad(_amount, _amountDecimals, _price, _priceDecimals, _rounding);
    }

    function ratioWad(uint256 _numerator, uint256 _denominator, Math.Rounding _rounding)
        external
        pure
        returns (uint256)
    {
        return DecimalMath.ratioWad(_numerator, _denominator, _rounding);
    }
}
