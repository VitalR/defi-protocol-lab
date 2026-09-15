// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { ReserveFactorAccounting } from "src/labs/lending/ReserveFactorAccounting.sol";

contract ReserveFactorAccountingTest is Test {
    ReserveFactorAccounting treasuryAccounting;

    function setUp() public {
        treasuryAccounting = new ReserveFactorAccounting();
    }

    function test_accrueTreasury() public {
        assertEq(treasuryAccounting.accruedToTreasury(), 0);

        assertEq(treasuryAccounting.accrueTreasury(480e6, 0), 0);
        assertEq(treasuryAccounting.accruedToTreasury(), 0);

        assertEq(treasuryAccounting.accrueTreasury(480e6, 0.1e18), 48e6);
        assertEq(treasuryAccounting.accruedToTreasury(), 48e6);

        // multiple accrual periods
        // → accruedToTreasury accumulates
        assertEq(treasuryAccounting.accrueTreasury(480e6, 1e18), 480e6);
        assertEq(treasuryAccounting.accruedToTreasury(), 48e6 + 480e6);
    }

    function test_accrueTreasury_revertsWhenInvalidReserveFactor() public {
        assertEq(treasuryAccounting.accruedToTreasury(), 0);

        vm.expectRevert(abi.encodeWithSelector(ReserveFactorAccounting.InvalidReserveFactor.selector, 1.01e18));
        treasuryAccounting.accrueTreasury(480e6, 1.01e18);

        assertEq(treasuryAccounting.accruedToTreasury(), 0);
    }

    function test_accrueTreasury_roundsDown() public {
        uint256 accrued = treasuryAccounting.accrueTreasury(101, 0.1e18);

        // 101 × 10%
        // = 10.1
        // → Floor
        // = 10

        // treasury claim <= exact protocol share
        assertEq(accrued, 10);
        assertEq(treasuryAccounting.accruedToTreasury(), 10);
    }
}
