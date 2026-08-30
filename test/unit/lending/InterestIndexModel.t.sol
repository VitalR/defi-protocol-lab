// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { InterestIndexModel } from "src/labs/lending/InterestIndexModel.sol";

contract InterestIndexModelTest is Test {
    InterestIndexModel indexModel;

    function setUp() public {
        vm.warp(block.timestamp + 365 days);

        indexModel = new InterestIndexModel();
    }

    function test_constructor_configuration() public {
        assertEq(indexModel.borrowIndex(), 1e18);
        assertEq(indexModel.lastUpdateTimestamp(), block.timestamp);
    }

    function test_previewBorrowIndex() public {
        uint256 lastUpdate = indexModel.lastUpdateTimestamp();

        assertEq(indexModel.previewBorrowIndex(0.1e18, lastUpdate), 1e18);

        assertEq(indexModel.previewBorrowIndex(0, lastUpdate + 365 days), 1e18);

        assertEq(indexModel.previewBorrowIndex(0.1e18, lastUpdate + 365 days), 1.1e18);

        assertEq(indexModel.previewBorrowIndex(0.1e18, lastUpdate + 182.5 days), 1.05e18);
    }

    function test_previewBorrowIndex_revertsWhenTimestampBeforeLastUpdate() public {
        uint256 lastUpdate = indexModel.lastUpdateTimestamp();

        vm.expectRevert(
            abi.encodeWithSelector(InterestIndexModel.InvalidTimestamp.selector, lastUpdate - 1, lastUpdate)
        );

        indexModel.previewBorrowIndex(0.1e18, lastUpdate - 1);
    }

    function test_updateBorrowIndex() public {
        assertEq(indexModel.borrowIndex(), 1e18);
        assertEq(indexModel.lastUpdateTimestamp(), block.timestamp);

        uint256 expectedTimestamp = indexModel.lastUpdateTimestamp() + 30 days;

        skip(30 days);
        indexModel.updateBorrowIndex(0.15e18);

        // index growth =
        // 15% × 30/365
        // ≈ 1.2328767%

        // 1.0
        // → 1.012328767...
        assertEq(indexModel.borrowIndex(), 1_012_328_767_123_287_672);
        assertEq(indexModel.lastUpdateTimestamp(), expectedTimestamp);
    }

    function test_updateBorrowIndex_compoundsAcrossUpdates() public {
        // linear accrual
        assertEq(indexModel.borrowIndex(), 1e18);

        skip(365 days);
        indexModel.updateBorrowIndex(0.1e18);

        assertEq(indexModel.borrowIndex(), 1.1e18);

        skip(365 days);
        indexModel.updateBorrowIndex(0.1e18);
        // but then index compounding
        assertEq(indexModel.borrowIndex(), 1.21e18);
    }

    function test_toScaledDebt() public {
        assertEq(indexModel.toScaledDebt(1000e6, 1e18), 1000e6);

        assertEq(indexModel.toScaledDebt(1000e6, 1.25e18), 800e6);
    }

    function test_toScaledDebt_revertsWhenInvalidIndex() public {
        vm.expectRevert(abi.encodeWithSelector(InterestIndexModel.InvalidIndex.selector, 0.9e18));
        indexModel.toScaledDebt(1000e6, 0.9e18);
    }

    function test_fromScaledDebt() public {
        // scaledDebt stays unchanged
        // borrowIndex grows
        // => actualDebt grows
        assertEq(indexModel.fromScaledDebt(800e6, 1.25e18), 1000e6);

        assertEq(indexModel.fromScaledDebt(800e6, 1.4e18), 1120e6);
    }

    function test_fromScaledDebt_revertsWhenInvalidIndex() public {
        vm.expectRevert(abi.encodeWithSelector(InterestIndexModel.InvalidIndex.selector, 0.9e18));
        indexModel.fromScaledDebt(800e6, 0.9e18);
    }

    function test_toScaledDebt_fromScaledDebt_rounding() public {
        uint256 actualDebt = 1000e6;
        uint256 index = 1.3e18;

        uint256 scaled = indexModel.toScaledDebt(actualDebt, index);
        uint256 reconstructed = indexModel.fromScaledDebt(scaled, index);

        assertGe(reconstructed, actualDebt);
    }

    function test_scaledDebtForBorrow() public {
        // index = 1.25
        // borrow 250
        // → scaled +200
        assertEq(indexModel.scaledDebtForBorrow(250e6, 1.25e18), 200e6);
    }

    function test_scaledDebtForBorrow_revertsWhenInvalidIndex() public {
        vm.expectRevert(abi.encodeWithSelector(InterestIndexModel.InvalidIndex.selector, 0.9e18));
        indexModel.scaledDebtForBorrow(1000e6, 0.9e18);
    }

    function test_scaledDebtForRepay() public {
        // index = 1.25
        // repay 250
        // → scaled -200
        assertEq(indexModel.scaledDebtForRepay(250e6, 1.25e18), 200e6);
    }

    function test_scaledDebtForRepay_revertsWhenInvalidIndex() public {
        vm.expectRevert(abi.encodeWithSelector(InterestIndexModel.InvalidIndex.selector, 0.9e18));
        indexModel.scaledDebtForRepay(800e6, 0.9e18);
    }
}
