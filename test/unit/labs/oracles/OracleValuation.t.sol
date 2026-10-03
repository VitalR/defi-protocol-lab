// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { OracleValuation } from "src/labs/oracles/OracleValuation.sol";
import { OracleValuationHarness } from "test/helpers/OracleValuationHarness.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";

contract OracleValuationTest is Test {
    OracleValuationHarness harness;

    function setUp() public {
        harness = new OracleValuationHarness();
    }

    // priceWad = 2,000e18 USD/ETH
    function test_ValueInWad_18decimalAssetValuation() public {
        uint256 valueWad = harness.valueInWad(2e18, 18, 2000e18, Math.Rounding.Ceil);
        assertEq(valueWad, 4000e18);
    }

    // priceWad = 1e18 USD/USDC
    function test_ValueInWad_6decimalAssetValuation() public {
        uint256 valueWad = harness.valueInWad(1500e6, 6, 1e18, Math.Rounding.Ceil);
        assertEq(valueWad, 1500e18);
    }

    function test_ValueInWad_8decimalAssetValuation() public {
        uint256 valueWad = harness.valueInWad(1e8, 8, 1e18, Math.Rounding.Ceil);
        assertEq(valueWad, 1e18);
    }

    function test_ValueInWad_Reverts_UnsupportedTokenDecimals() public {
        vm.expectRevert(abi.encodeWithSelector(OracleValuation.UnsupportedTokenDecimals.selector, 19));
        harness.valueInWad(1e8, 19, 1e18, Math.Rounding.Ceil);
    }

    function test_ValueInWad_Reverts_ZeroPrice() public {
        vm.expectRevert(OracleValuation.ZeroPrice.selector);
        harness.valueInWad(2e18, 18, 0, Math.Rounding.Ceil);
    }

    function test_ValueInWad_ZeroAmountReturnsZero() public {
        uint256 valueWad = harness.valueInWad(0, 18, 2000e18, Math.Rounding.Floor);

        assertEq(valueWad, 0);
    }

    function test_ValueInWad_NonExactDivisionRespectsRounding() public {
        uint256 amount = 1;
        uint256 priceWad = 1e18 + 1;

        uint256 floorValue = harness.valueInWad(amount, 18, priceWad, Math.Rounding.Floor);
        uint256 ceilValue = harness.valueInWad(amount, 18, priceWad, Math.Rounding.Ceil);

        assertEq(floorValue, 1);
        assertEq(ceilValue, 2);
    }

    function test_AmountFromValueWad_ZeroValueReturnsZero() public {
        uint256 amount = harness.amountFromValueWad(0, 18, 2000e18, Math.Rounding.Ceil);

        assertEq(amount, 0);
    }

    function test_AmountFromValueWad_Reverts_UnsupportedTokenDecimals() public {
        vm.expectRevert(abi.encodeWithSelector(OracleValuation.UnsupportedTokenDecimals.selector, 21));
        harness.amountFromValueWad(4000e18, 21, 2000e18, Math.Rounding.Floor);
    }

    function test_AmountFromValueWad_Reverts_ZeroPrice() public {
        vm.expectRevert(OracleValuation.ZeroPrice.selector);
        harness.amountFromValueWad(4000e18, 18, 0, Math.Rounding.Floor);
    }

    // $4,000 / $2,000 per ETH = 2 ETH
    function test_AmountFromValueWad_ExactConversion() public {
        uint256 amount = harness.amountFromValueWad(4000e18, 18, 2000e18, Math.Rounding.Floor);

        assertEq(amount, 2e18);
    }

    // value = $1
    // price = $3 per token
    // token decimals = 6

    // 1e18 × 1e6 / 3e18 = 333,333.333...
    function test_AmountFromValueWad_NonExactDivisionRoundsDown() public {
        uint256 amount = harness.amountFromValueWad(1e18, 6, 3e18, Math.Rounding.Floor);

        assertEq(amount, 333_333);
    }

    function test_AmountFromValueWad_NonExactDivisionRoundsUp() public {
        uint256 amount = harness.amountFromValueWad(1e18, 6, 3e18, Math.Rounding.Ceil);

        assertEq(amount, 333_334);
    }

    function test_ValueInWad_LargeValuesUsesMulDivSafely() public {
        uint256 amount = type(uint256).max;

        uint256 valueWad = harness.valueInWad(amount, 18, 1e18, Math.Rounding.Floor);

        assertEq(valueWad, type(uint256).max);
    }

    function test_AmountFromValueWad_LargeValuesUsesMulDivSafely() public {
        uint256 amount = harness.amountFromValueWad(type(uint256).max, 18, 1e18, Math.Rounding.Floor);

        assertEq(amount, type(uint256).max);
    }

    function testFuzz_ValueInWad_MatchesFormulaWithinSafeBounds(uint256 rawAmount, uint256 rawPrice, uint8 rawDecimals)
        public
    {
        uint8 tokenDecimals = uint8(bound(uint256(rawDecimals), 0, 18));
        uint256 priceWad = bound(rawPrice, 1, 1e30);

        uint256 amount = bound(rawAmount, 0, type(uint256).max / priceWad);
        uint256 tokenUnit = 10 ** tokenDecimals;

        uint256 expectedValue = amount * priceWad / tokenUnit;

        uint256 actualValue = harness.valueInWad(amount, tokenDecimals, priceWad, Math.Rounding.Floor);

        assertEq(actualValue, expectedValue);
    }

    function testFuzz_RoundTripFloor_DoesNotCreateTokenAmount(uint256 rawAmount, uint256 rawPrice, uint8 rawDecimals)
        public
    {
        uint8 tokenDecimals = uint8(bound(uint256(rawDecimals), 0, 18));
        uint256 priceWad = bound(rawPrice, 1, 1e30);
        uint256 amount = bound(rawAmount, 0, type(uint256).max / priceWad);

        uint256 valueWad = harness.valueInWad(amount, tokenDecimals, priceWad, Math.Rounding.Floor);

        uint256 recoveredAmount = harness.amountFromValueWad(valueWad, tokenDecimals, priceWad, Math.Rounding.Floor);

        assertLe(recoveredAmount, amount);
    }

    function testFuzz_CeilAmountCoversRequestedValue(uint256 rawValueWad, uint256 rawPrice, uint8 rawDecimals) public {
        uint8 tokenDecimals = uint8(bound(uint256(rawDecimals), 0, 18));
        uint256 priceWad = bound(rawPrice, 1, 1e30);

        // Leaves ample headroom for:
        // 1. ceil rounding in amountFromValueWad;
        // 2. revaluation in valueInWad;
        // 3. every supported token-decimal configuration.
        uint256 requestedValueWad = bound(rawValueWad, 0, 1e36);

        uint256 requiredAmount =
            harness.amountFromValueWad(requestedValueWad, tokenDecimals, priceWad, Math.Rounding.Ceil);

        uint256 coveredValueWad = harness.valueInWad(requiredAmount, tokenDecimals, priceWad, Math.Rounding.Floor);

        assertGe(coveredValueWad, requestedValueWad);
    }
}

// Required test cases
// Cover:

// 18-decimal asset valuation;
// 6-decimal asset valuation;
// 8-decimal asset valuation;
// zero amount;
// zero price rejection;
// token decimals above 18 rejection;
// exact reverse conversion;
// non-exact division with Floor;
// non-exact division with Ceil;
// very large values demonstrating mulDiv safety;
// fuzz test against the mathematical formula within safe bounds;
// round-trip property:
// floor conversion must not create value;
// ceil conversion must provide enough tokens to cover the requested value.
