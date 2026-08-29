// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { InterestRateModel } from "src/labs/lending/InterestRateModel.sol";

contract InterestRateModelTest is Test {
    InterestRateModel rateModel;

    function setUp() public {
        rateModel = new InterestRateModel();
    }

    function test_utilization() public {
        assertEq(rateModel.utilization(0, 0), 0);

        assertEq(rateModel.utilization(1000, 0), 0);

        assertEq(rateModel.utilization(800, 200), 0.2e18);

        assertEq(rateModel.utilization(200, 800), 0.8e18);

        assertEq(rateModel.utilization(0, 1000), 1e18);
    }

    function test_borrowRate() public {
        assertEq(rateModel.borrowRate(0), rateModel.BASE_RATE());

        assertEq(rateModel.borrowRate(0.4e18), 0.04e18);

        assertEq(rateModel.borrowRate(0.8e18), 0.06e18);

        assertEq(rateModel.borrowRate(0.9e18), 0.435e18);

        assertEq(rateModel.borrowRate(1e18), 0.81e18);
    }

    function test_borrowRate_revertsWhenInvalidUtilization() public {
        vm.expectRevert(abi.encodeWithSelector(InterestRateModel.InvalidUtilization.selector, 1.1e18));
        rateModel.borrowRate(1.1e18);
    }

    function test_supplyRate() public {
        assertEq(rateModel.supplyRate(0, 0.02e18), 0);

        assertEq(rateModel.supplyRate(0.5e18, 0.1e18), 0.045e18);

        assertEq(rateModel.supplyRate(0.8e18, 0.06e18), 0.0432e18);

        assertEq(rateModel.supplyRate(1e18, 0.81e18), 0.729e18);
    }

    function test_supplyRate_revertsWhenInvalidUtilization() public {
        vm.expectRevert(abi.encodeWithSelector(InterestRateModel.InvalidUtilization.selector, 1.1e18));
        rateModel.supplyRate(1.1e18, 0.1e18);
    }
}
