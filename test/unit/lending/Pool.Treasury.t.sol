// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import { Pool } from "src/lending/Pool.sol";
import { PoolAddressProvider } from "src/lending/PoolAddressProvider.sol";
import { PoolConfigurator } from "src/lending/PoolConfigurator.sol";
import { ScaledSupplyToken } from "src/lending/tokens/ScaledSupplyToken.sol";
import { ScaledDebtToken } from "src/lending/tokens/ScaledDebtToken.sol";
import { DataTypes } from "src/lending/libraries/DataTypes.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";
import { MockWETH } from "test/mocks/MockWETH.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";
import { PoolHarness } from "test/helpers/PoolHarness.sol";

import { AssetOracleRouter } from "src/lending/oracles/AssetOracleRouter.sol";
import { PushOracleAdapter } from "src/lending/oracles/adapters/PushOracleAdapter.sol";
import { IPriceOracle } from "src/lending/oracles/interfaces/IPriceOracle.sol";
import { MockAggregatorV3 } from "test/mocks/MockAggregatorV3.sol";

contract PoolTreasuryTest is Test {
    PoolHarness pool;
    PoolAddressProvider provider;
    PoolConfigurator configurator;
    AssetOracleRouter router;
    MockAggregatorV3 wethFeed;
    MockAggregatorV3 usdcFeed;
    MockWETH weth;
    MockUSDC usdc;

    address admin = address(0x1000);
    address alice = address(0x1001);
    address bob = address(0x1002);
    address charlie = address(0x1003);

    address treasury = address(0x2000);
    address newTreasury = address(0x2001);

    event MintedToTreasury(address indexed asset, address indexed treasury, uint256 actualAmount, uint256 scaledAmount);

    function setUp() public {
        provider = new PoolAddressProvider(admin);
        configurator = new PoolConfigurator(admin, address(provider));
        pool = new PoolHarness(address(provider));
        router = new AssetOracleRouter(admin);
        weth = new MockWETH();
        usdc = new MockUSDC();
    }

    function _deployUsdcOracleAdapter() internal returns (PushOracleAdapter) {
        usdcFeed = new MockAggregatorV3(1, 8, "MockAggregatorV3::USDC/USD");

        usdcFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1, answer: 1e8, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 1
            })
        );

        return new PushOracleAdapter(address(usdcFeed), bytes32("USDC"), bytes32("USD"), 1 hours);
    }

    function _configureUsdcOracle() internal {
        PushOracleAdapter usdcAdapter = _deployUsdcOracleAdapter();

        vm.prank(admin);
        router.setOracleConfig(address(usdc), IPriceOracle(address(usdcAdapter)), bytes32("USDC"), 6);
    }

    function _deployWethOracleAdapter() internal returns (PushOracleAdapter) {
        wethFeed = new MockAggregatorV3(1, 8, "MockAggregatorV3::ETH/USD");

        wethFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1, answer: 2000e8, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 1
            })
        );

        return new PushOracleAdapter(address(wethFeed), bytes32("ETH"), bytes32("USD"), 1 hours);
    }

    function _configureWethOracle() internal {
        PushOracleAdapter wethAdapter = _deployWethOracleAdapter();

        vm.prank(admin);
        router.setOracleConfig(address(weth), IPriceOracle(address(wethAdapter)), bytes32("ETH"), 18);
    }

    function _registerMarketContracts() internal {
        vm.startPrank(admin);
        provider.setPool(address(pool));
        provider.setPoolConfigurator(address(configurator));
        provider.setPriceOracle(address(router));
        vm.stopPrank();
    }

    function _initializeWethReserve() internal {
        vm.startPrank(admin);
        configurator.initReserve(address(weth));
        configurator.configureReserve(address(weth), 0.75e18, 0.8e18, 1.05e18, false);
        vm.stopPrank();
    }

    function _initializeUsdcReserve() internal {
        vm.startPrank(admin);
        configurator.initReserve(address(usdc));
        configurator.configureReserve(address(usdc), 0, 0, 0, true);
        vm.stopPrank();
    }

    function _setupWethReserve() internal {
        _configureWethOracle();
        _initializeWethReserve();
    }

    function _setupUsdcReserve() internal {
        _configureUsdcOracle();
        _initializeUsdcReserve();
    }

    function _setupUsdcLoan() internal {
        _registerMarketContracts();
        _setupWethReserve();
        _setupUsdcReserve();

        weth.mint(alice, 1 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        pool.supply(address(weth), 1 ether, alice);
        pool.setUserUseReserveAsCollateral(address(weth), true);
        vm.stopPrank();

        usdc.mint(bob, 2000e6);

        vm.startPrank(bob);
        usdc.approve(address(pool), 2000e6);
        pool.supply(address(usdc), 2000e6, bob);
        vm.stopPrank();

        vm.prank(alice);
        pool.borrow(address(usdc), 1000e6, alice);
    }

    function test_mintToTreasury_afterYear() public {
        _setupUsdcLoan();

        vm.prank(admin);
        provider.setTreasury(treasury);

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken supplyToken = ScaledSupplyToken(reserve.supplyToken);

        skip(365 days);

        uint256 expectedIndex = 1.02025e18;

        uint256 expectedScaled = Math.mulDiv(4.5e6, DecimalMath.WAD, expectedIndex, Math.Rounding.Floor);

        uint256 expectedActual = Math.mulDiv(expectedScaled, expectedIndex, DecimalMath.WAD, Math.Rounding.Floor);

        uint256 cashBefore = pool.availableLiquidity(address(usdc));
        uint256 debtBefore = pool.totalDebt(address(usdc));

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);

        vm.expectEmit(true, true, false, true, address(pool));
        emit MintedToTreasury(address(usdc), treasury, expectedActual, expectedScaled);

        // Mint is permissionless.
        vm.prank(charlie);
        pool.mintToTreasury(assets);

        reserve = pool.getReserveData(address(usdc));

        assertEq(reserve.state.accruedToTreasuryScaled, 0);
        assertEq(reserve.state.borrowIndex, 1.045e18);
        assertEq(reserve.state.liquidityIndex, expectedIndex);
        assertEq(reserve.state.lastUpdateTimestamp, block.timestamp);

        assertEq(expectedScaled, 4_410_683);
        assertEq(expectedActual, 4_499_999);

        assertEq(supplyToken.scaledBalanceOf(treasury), expectedScaled);
        assertEq(supplyToken.balanceOf(treasury), expectedActual);

        assertEq(supplyToken.scaledBalanceOf(bob), 2000e6);
        assertEq(supplyToken.balanceOf(bob), 2040.5e6);

        assertEq(supplyToken.scaledTotalSupply(), 2000e6 + expectedScaled);

        // Mint creates claims; it does not transfer underlying.
        assertEq(pool.availableLiquidity(address(usdc)), cashBefore);
        assertEq(usdc.balanceOf(reserve.supplyToken), cashBefore);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(pool.totalDebt(address(usdc)), debtBefore);

        assertFalse(pool.isUsingAsCollateral(treasury, address(usdc)));
    }

    function test_mintToTreasury_doesNotMintTwice() public {
        _setupUsdcLoan();

        vm.prank(admin);
        provider.setTreasury(treasury);

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));
        ScaledSupplyToken supplyToken = ScaledSupplyToken(reserve.supplyToken);

        skip(365 days);

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);

        vm.prank(charlie);
        pool.mintToTreasury(assets);

        reserve = pool.getReserveData(address(usdc));

        assertEq(reserve.state.accruedToTreasuryScaled, 0);
        assertEq(reserve.state.borrowIndex, 1.045e18);
        assertEq(reserve.state.liquidityIndex, 1.02025e18);
        assertEq(reserve.state.lastUpdateTimestamp, block.timestamp);

        uint256 treasuryScaledBefore = supplyToken.scaledBalanceOf(treasury);

        uint256 totalScaledBefore = supplyToken.scaledTotalSupply();

        pool.mintToTreasury(assets);

        assertEq(supplyToken.scaledBalanceOf(treasury), treasuryScaledBefore);

        assertEq(supplyToken.scaledTotalSupply(), totalScaledBefore);

        assertEq(pool.getReserveData(address(usdc)).state.accruedToTreasuryScaled, 0);
    }

    function test_mintToTreasury_afterTwoIntervals_preservesBacking() public {
        _setupUsdcLoan();

        vm.prank(admin);
        provider.setTreasury(treasury);

        skip(365 days);

        vm.startPrank(alice);
        usdc.approve(address(pool), 100e6);
        pool.repay(address(usdc), 100e6, alice);
        vm.stopPrank();

        uint256 debtBefore = pool.totalDebt(address(usdc));

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));
        ScaledSupplyToken supplyToken = ScaledSupplyToken(reserve.supplyToken);

        uint256 pendingScaled = reserve.state.accruedToTreasuryScaled;

        assertEq(pendingScaled, 4_410_683);
        assertEq(supplyToken.scaledBalanceOf(treasury), 0);

        skip(365 days);

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);

        uint256 debtAfter = pool.totalDebt(address(usdc));

        assertGt(debtAfter, debtBefore);

        assertEq(supplyToken.scaledBalanceOf(treasury), 0);

        uint256 secondIntervalAccrual =
            Math.mulDiv(debtAfter - debtBefore, reserve.state.reserveFactor, DecimalMath.WAD, Math.Rounding.Floor);

        uint256 expectedTreasuryScaled = pendingScaled
            + Math.mulDiv(
                secondIntervalAccrual, DecimalMath.WAD, pool.currentLiquidityIndex(address(usdc)), Math.Rounding.Floor
            );

        vm.prank(admin);
        pool.mintToTreasury(assets);

        assertGt(supplyToken.scaledBalanceOf(treasury), pendingScaled);

        assertEq(pool.getReserveData(address(usdc)).state.accruedToTreasuryScaled, 0);

        assertEq(supplyToken.scaledBalanceOf(treasury), expectedTreasuryScaled);

        uint256 assetsValue = pool.availableLiquidity(address(usdc)) + pool.totalDebt(address(usdc));

        uint256 claimsValue = pool.totalSupply(address(usdc));

        assertLe(claimsValue, assetsValue);
    }

    function _setupLoanAndMintTreasuryAfterYear() internal {
        _setupUsdcLoan();

        vm.prank(admin);
        provider.setTreasury(treasury);

        skip(365 days);

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);

        vm.prank(charlie);
        pool.mintToTreasury(assets);
    }

    function test_mintToTreasury_claimCanBeWithdrawn() public {
        _setupLoanAndMintTreasuryAfterYear();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));
        ScaledSupplyToken supplyToken = ScaledSupplyToken(reserve.supplyToken);

        uint256 treasuryClaim = supplyToken.balanceOf(treasury);
        uint256 cashBefore = pool.availableLiquidity(address(usdc));

        vm.prank(charlie);
        vm.expectRevert(Pool.ZeroAmount.selector);
        pool.withdraw(address(usdc), type(uint256).max, charlie);

        vm.prank(treasury);
        uint256 withdrawn = pool.withdraw(address(usdc), type(uint256).max, treasury);

        assertEq(withdrawn, treasuryClaim);
        assertEq(usdc.balanceOf(treasury), treasuryClaim);
        assertEq(supplyToken.scaledBalanceOf(treasury), 0);

        assertEq(pool.availableLiquidity(address(usdc)), cashBefore - treasuryClaim);
    }

    function test_mintToTreasury_revertsWithoutTreasury() public {
        _setupUsdcLoan();

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);

        vm.expectRevert(Pool.TreasuryNotConfigured.selector);
        pool.mintToTreasury(assets);
    }

    function test_mintToTreasury_usesUpdatedRecipient() public {
        _setupLoanAndMintTreasuryAfterYear();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));
        ScaledSupplyToken supplyToken = ScaledSupplyToken(reserve.supplyToken);

        uint256 oldTreasuryScaled = supplyToken.scaledBalanceOf(treasury);

        vm.expectRevert(); // NotOwner
        provider.setTreasury(newTreasury);

        vm.prank(admin);
        vm.expectRevert(PoolAddressProvider.ZeroAddress.selector);
        provider.setTreasury(address(0));

        vm.prank(admin);
        provider.setTreasury(newTreasury);

        skip(365 days);

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);

        pool.mintToTreasury(assets);

        assertEq(supplyToken.scaledBalanceOf(treasury), oldTreasuryScaled);

        assertGt(supplyToken.scaledBalanceOf(newTreasury), 0);
    }
}
