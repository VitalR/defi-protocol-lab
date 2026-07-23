// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { DecimalMath } from "src/common/math/DecimalMath.sol";
import { OracleValuation } from "src/labs/oracles/OracleValuation.sol";
import { IPriceOracle } from "src/labs/oracles/PushOracleAdapter.sol";

contract CollateralValueOracle {
    error ZeroOracle();
    error UnsupportedTokenDecimals(uint8 decimals);

    IPriceOracle public immutable oracle;
    uint8 public immutable tokenDecimals;

    constructor(IPriceOracle _oracle, uint8 _tokenDecimals) {
        require(address(_oracle) != address(0), ZeroOracle());

        if (_tokenDecimals > DecimalMath.WAD_DECIMALS) {
            revert UnsupportedTokenDecimals(_tokenDecimals);
        }

        oracle = _oracle;
        tokenDecimals = _tokenDecimals;
    }

    function collateralValue(uint256 amount) external view returns (uint256 valueWad, uint256 updatedAt) {
        (uint256 priceWad, uint256 priceUpdatedAt) = oracle.latestPrice();

        valueWad = OracleValuation.valueInWad(amount, tokenDecimals, priceWad, Math.Rounding.Floor);

        updatedAt = priceUpdatedAt;
    }

    function debtValue(uint256 amount) external view returns (uint256 valueWad, uint256 updatedAt) {
        (uint256 priceWad, uint256 priceUpdatedAt) = oracle.latestPrice();

        valueWad = OracleValuation.valueInWad(amount, tokenDecimals, priceWad, Math.Rounding.Ceil);

        updatedAt = priceUpdatedAt;
    }
}
