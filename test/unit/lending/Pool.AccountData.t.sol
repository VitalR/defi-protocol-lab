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
import { MockWBTC } from "test/mocks/MockWBTC.sol";
import { MockERC20Decimals } from "test/mocks/MockERC20Decimals.sol";
import { MockFeeOnTransferERC20 } from "test/mocks/MockFeeOnTransferERC20.sol";
import { PoolHarness } from "test/helpers/PoolHarness.sol";

import { AssetOracleRouter } from "src/lending/oracles/AssetOracleRouter.sol";
import { PushOracleAdapter } from "src/lending/oracles/adapters/PushOracleAdapter.sol";
import { IPriceOracle } from "src/lending/oracles/interfaces/IPriceOracle.sol";
import { MockAggregatorV3 } from "test/mocks/MockAggregatorV3.sol";

contract PoolAccountDataTest is Test {
    Pool pool;
    PoolAddressProvider provider;
    PoolConfigurator configurator;
    AssetOracleRouter router;
    MockAggregatorV3 wethFeed;
    MockAggregatorV3 wbtcFeed;
    MockAggregatorV3 usdcFeed;
    MockWETH weth;
    MockUSDC usdc;
    MockWBTC wbtc;

    address admin = address(0x1000);
    address alice = address(0x1001);
    address bob = address(0x1002);
    address borrower = address(0x1003);

    function setUp() public {
        provider = new PoolAddressProvider(admin);
        configurator = new PoolConfigurator(admin, address(provider));
        pool = new PoolHarness(address(provider));
        router = new AssetOracleRouter(admin);
        weth = new MockWETH();
        usdc = new MockUSDC();
        wbtc = new MockWBTC();
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

    function _deployWbtcOracleAdapter() internal returns (PushOracleAdapter) {
        wbtcFeed = new MockAggregatorV3(1, 8, "MockAggregatorV3::WBTC/USD");

        wbtcFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1, answer: 60_000e8, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 1
            })
        );

        return new PushOracleAdapter(address(wbtcFeed), bytes32("WBTC"), bytes32("USD"), 1 hours);
    }

    function _configureWbtcOracle() internal {
        PushOracleAdapter wbtcAdapter = _deployWbtcOracleAdapter();

        vm.prank(admin);
        router.setOracleConfig(address(wbtc), IPriceOracle(address(wbtcAdapter)), bytes32("WBTC"), 8);
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
        configurator.configureReserve(address(weth), 0.75e18, 0.8e18, false);
        vm.stopPrank();
    }

    function _initializeWbtcReserve() internal {
        vm.startPrank(admin);
        configurator.initReserve(address(wbtc));
        configurator.configureReserve(address(wbtc), 0.7e18, 0.75e18, false);
        vm.stopPrank();
    }

    function _initializeUsdcReserve() internal {
        vm.startPrank(admin);
        configurator.initReserve(address(usdc));
        configurator.configureReserve(address(usdc), 0, 0, true);
        vm.stopPrank();
    }

    function _setupWethReserve() internal {
        _configureWethOracle();
        _initializeWethReserve();
    }

    function _setupWbtcReserve() internal {
        _configureWbtcOracle();
        _initializeWbtcReserve();
    }

    function _setupUsdcReserve() internal {
        _configureUsdcOracle();
        _initializeUsdcReserve();
    }

    function test_getUserAccountData_tracksCollateralToggle() public {
        _registerMarketContracts();
        _setupWethReserve();

        weth.mint(alice, 1 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        pool.supply(address(weth), 1 ether, alice);

        DataTypes.AccountData memory data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 0e18);
        assertEq(data.debtValueWad, 0);
        assertEq(data.borrowCapacityWad, 0e18);
        assertEq(data.liquidationCapacityWad, 0e18);
        assertEq(data.availableBorrowsWad, 0e18);
        assertEq(data.healthFactorWad, type(uint256).max);

        pool.setUserUseReserveAsCollateral(address(weth), true);
        vm.stopPrank();

        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 2000e18);
        assertEq(data.debtValueWad, 0);
        assertEq(data.borrowCapacityWad, 1500e18);
        assertEq(data.liquidationCapacityWad, 1600e18);
        assertEq(data.availableBorrowsWad, 1500e18);
        assertEq(data.healthFactorWad, type(uint256).max);

        vm.prank(alice);
        pool.setUserUseReserveAsCollateral(address(weth), false);

        data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 0e18);
        assertEq(data.debtValueWad, 0);
        assertEq(data.borrowCapacityWad, 0e18);
        assertEq(data.liquidationCapacityWad, 0e18);
        assertEq(data.availableBorrowsWad, 0e18);
        assertEq(data.healthFactorWad, type(uint256).max);

        assertFalse(pool.isUsingAsCollateral(alice, address(weth)));

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));

        assertEq(ScaledSupplyToken(reserve.supplyToken).balanceOf(alice), 1 ether);
    }

    function test_getUserAccountData_sumsTwoCollateralReserves() public {
        _registerMarketContracts();
        _setupWethReserve();

        weth.mint(alice, 1 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        pool.supply(address(weth), 1 ether, alice);

        pool.setUserUseReserveAsCollateral(address(weth), true);
        vm.stopPrank();

        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        DataTypes.AccountData memory data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 2000e18);
        assertEq(data.debtValueWad, 0);
        assertEq(data.borrowCapacityWad, 1500e18);
        assertEq(data.liquidationCapacityWad, 1600e18);
        assertEq(data.availableBorrowsWad, 1500e18);
        assertEq(data.healthFactorWad, type(uint256).max);

        _setupWbtcReserve();

        wbtc.mint(alice, 0.5e8);

        vm.startPrank(alice);
        wbtc.approve(address(pool), 0.5e8);
        pool.supply(address(wbtc), 0.5e8, alice);

        pool.setUserUseReserveAsCollateral(address(wbtc), true);
        vm.stopPrank();

        assertTrue(pool.isUsingAsCollateral(alice, address(wbtc)));

        data = pool.getUserAccountData(alice);

        // 1 WETH × $2,000 + 0.5 WBTC × $60,000
        assertEq(data.collateralValueWad, 32_000e18);
        assertEq(data.debtValueWad, 0);

        // $2,000 × 75% + $30,000 × 70%
        assertEq(data.borrowCapacityWad, 22_500e18);

        // $2,000 × 80% + $30,000 × 75%
        assertEq(data.liquidationCapacityWad, 24_100e18);

        assertEq(data.availableBorrowsWad, 22_500e18);
        assertEq(data.healthFactorWad, type(uint256).max);
    }

    function test_getUserAccountData_withUsdcDebt() public {
        _registerMarketContracts();
        _setupWethReserve();

        weth.mint(alice, 1 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        pool.supply(address(weth), 1 ether, alice);

        pool.setUserUseReserveAsCollateral(address(weth), true);
        vm.stopPrank();

        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        DataTypes.AccountData memory data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 2000e18);
        assertEq(data.debtValueWad, 0);
        assertEq(data.borrowCapacityWad, 1500e18);
        assertEq(data.liquidationCapacityWad, 1600e18);
        assertEq(data.availableBorrowsWad, 1500e18);
        assertEq(data.healthFactorWad, type(uint256).max);

        _setupUsdcReserve();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        ScaledDebtToken debtToken = ScaledDebtToken(reserve.debtToken);

        vm.prank(address(pool));
        debtToken.mintScaled(alice, 1000e6);

        data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 2000e18);
        assertEq(data.debtValueWad, 1000e18);
        assertEq(data.borrowCapacityWad, 1500e18);
        assertEq(data.liquidationCapacityWad, 1600e18);
        assertEq(data.availableBorrowsWad, 500e18);
        assertEq(data.healthFactorWad, 1.6e18);
    }
}
