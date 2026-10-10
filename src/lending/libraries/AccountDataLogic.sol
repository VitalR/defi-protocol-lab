// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IAssetOracle } from "src/lending/interfaces/IAssetOracle.sol";
import { DataTypes } from "src/lending/libraries/DataTypes.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";
import { ScaledSupplyToken } from "src/lending/tokens/ScaledSupplyToken.sol";
import { ScaledDebtToken } from "src/lending/tokens/ScaledDebtToken.sol";

library AccountDataLogic {
    function calculateUserAccountData(
        mapping(address => DataTypes.ReserveData) storage reserves,
        address[] storage reservesList,
        mapping(address => mapping(address => bool)) storage usingAsCollateral,
        address user,
        IAssetOracle oracle
    ) internal view returns (DataTypes.AccountData memory data) {
        for (uint256 i; i < reservesList.length; ++i) {
            address asset = reservesList[i];

            DataTypes.ReserveData storage reserve = reserves[asset];
            DataTypes.ReserveConfiguration storage config = reserve.configuration;

            if (usingAsCollateral[user][asset] && config.liquidationThresholdWad > 0) {
                uint256 supplyBalance = ScaledSupplyToken(reserve.supplyToken).balanceOf(user);

                if (supplyBalance > 0) {
                    (uint256 collateralValueWad,) = oracle.collateralValueOf(asset, supplyBalance);

                    data.collateralValueWad += collateralValueWad;

                    data.borrowCapacityWad += Math.mulDiv(
                        collateralValueWad, config.ltvWad, DecimalMath.WAD, Math.Rounding.Floor
                    );

                    data.liquidationCapacityWad += Math.mulDiv(
                        collateralValueWad, config.liquidationThresholdWad, DecimalMath.WAD, Math.Rounding.Floor
                    );
                }
            }

            uint256 debtBalance = ScaledDebtToken(reserve.debtToken).balanceOf(user);

            if (debtBalance > 0) {
                (uint256 debtValueWad,) = oracle.debtValueOf(asset, debtBalance);

                data.debtValueWad += debtValueWad;
            }
        }

        data.availableBorrowsWad =
            data.borrowCapacityWad > data.debtValueWad ? data.borrowCapacityWad - data.debtValueWad : 0;

        data.healthFactorWad = data.debtValueWad == 0
            ? type(uint256).max
            : Math.mulDiv(data.liquidationCapacityWad, DecimalMath.WAD, data.debtValueWad, Math.Rounding.Floor);
    }
}
