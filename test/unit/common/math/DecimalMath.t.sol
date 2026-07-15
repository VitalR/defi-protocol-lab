// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";
import { DecimalMathHarness } from "test/helpers/DecimalMathHarness.sol";

contract DecimalMathTest is Test {
    DecimalMathHarness harness;

    function setUp() public {
        harness = new DecimalMathHarness();
    }

    function test_ScaleUpFromSixToEighteen() public {
        uint256 result = DecimalMath.scale(3e6, 6, 18, Math.Rounding.Ceil);
        assertEq(result, 3e18);
    }

    function test_ScaleUpFromEightToEighteen() public {
        uint256 result = DecimalMath.scale(3e8, 8, 18, Math.Rounding.Ceil);
        assertEq(result, 3e18);
    }

    //  Human notation: 1.234567890123456789
    //  Raw Solidity integer: 1_234_567_890_123_456_789
    function test_ScaleDownUsesFloorRounding() public {
        uint256 amount = 1_234_567_890_123_456_789;
        uint256 result = DecimalMath.scale(amount, 18, 6, Math.Rounding.Floor);
        assertEq(result, 1_234_567);
    }

    function test_ScaleDownUsesCeilRounding() public {
        uint256 amount = 1_234_567_890_123_456_789;
        uint256 result = DecimalMath.scale(amount, 18, 6, Math.Rounding.Ceil);
        assertEq(result, 1_234_568);
    }

    function test_ScaleWithEqualDecimalsReturnsOriginalAmount() public {
        uint256 result = DecimalMath.scale(3e6, 18, 18, Math.Rounding.Ceil);
        assertEq(result, 3e6);
    }

    function test_ScaleZeroReturnsZero() public {
        uint256 result = DecimalMath.scale(0, 18, 18, Math.Rounding.Ceil);
        assertEq(result, 0);
    }

    function test_ScaleRevertsForUnsupportedSourceDecimals() public {
        vm.expectRevert(abi.encodeWithSelector(DecimalMath.UnsupportedDecimals.selector, 19));
        harness.scale(3e6, 19, 18, Math.Rounding.Ceil);
    }

    function test_ScaleRevertsForUnsupportedTargetDecimals() public {
        vm.expectRevert(abi.encodeWithSelector(DecimalMath.UnsupportedDecimals.selector, 21));
        harness.scale(3e6, 18, 21, Math.Rounding.Ceil);
    }

    function test_ValueInWadForEthPrice() public {
        uint256 result = DecimalMath.valueInWad(2e18, 18, 2000e8, 8, Math.Rounding.Floor);

        assertEq(result, 4000e18);
    }

    function test_ValueInWadForSixDecimalStablecoin() public {
        uint256 result = DecimalMath.valueInWad(3000e6, 6, 1e8, 8, Math.Rounding.Floor);

        assertEq(result, 3000e18);
    }

    function test_ValueInWadForEthPrice_RevertsWhenUnsupportedDecimals() public {
        vm.expectRevert(abi.encodeWithSelector(DecimalMath.UnsupportedDecimals.selector, 19));
        harness.valueInWad(3000e6, 19, 1e8, 8, Math.Rounding.Floor);
    }

    function test_RatioWad_RevertsWhenZeroDenominator() public {
        vm.expectRevert(DecimalMath.ZeroDenominator.selector);
        harness.ratioWad(3e18, 0, Math.Rounding.Floor);
    }

    function test_RatioWadPreservesFractionalPrecision() public {
        uint256 result = DecimalMath.ratioWad(3200e18, 3000e18, Math.Rounding.Floor);
        assertEq(result, 1_066_666_666_666_666_666);
    }
}
