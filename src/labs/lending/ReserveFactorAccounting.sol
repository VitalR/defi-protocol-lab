// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Math } from "src/common/math/DecimalMath.sol";

contract ReserveFactorAccounting {
    error InvalidReserveFactor(uint256 reserveFactor);

    uint256 internal constant WAD = 1e18;

    uint256 public accruedToTreasury;

    // validate reserveFactor <= WAD

    // treasuryAccrual
    // =
    // borrowInterestGenerated
    // × reserveFactor
    // / WAD

    // accruedToTreasury += treasuryAccrual
    function accrueTreasury(uint256 borrowInterestGenerated, uint256 reserveFactor) external returns (uint256) {
        require(reserveFactor <= WAD, InvalidReserveFactor(reserveFactor));

        uint256 treasuryAccrual = Math.mulDiv(borrowInterestGenerated, reserveFactor, WAD, Math.Rounding.Floor);

        accruedToTreasury += treasuryAccrual;

        return treasuryAccrual;
    }
}
