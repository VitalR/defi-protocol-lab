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
import { LiquidationMath } from "src/lending/libraries/LiquidationMath.sol";
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

contract PoolLiquidationTest is Test {
    PoolHarness pool;
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
    address charlie = address(0x1003);

    event Borrowed(
        address indexed asset, address indexed caller, address indexed onBehalfOf, uint256 amount, uint256 scaledAmount
    );
    event BorrowAllowanceDelegated(
        address indexed delegator, address indexed delegatee, address indexed asset, uint256 amount
    );
    event Repaid(
        address indexed asset, address indexed payer, address indexed onBehalfOf, uint256 amount, uint256 scaledAmount
    );
    event LiquidationCall(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed user,
        uint256 debtRepaid,
        uint256 collateralSeized,
        address liquidator,
        bool receiveSupplyToken
    );

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
        configurator.configureReserve(address(weth), 0.75e18, 0.8e18, 1.05e18, false);
        vm.stopPrank();
    }

    function _initializeWbtcReserve() internal {
        vm.startPrank(admin);
        configurator.initReserve(address(wbtc));
        configurator.configureReserve(address(wbtc), 0.7e18, 0.75e18, 1.05e18, false);
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

    function _setupWbtcReserve() internal {
        _configureWbtcOracle();
        _initializeWbtcReserve();
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

    function test_liquidationMath() public {
        // debtBudget          = 500e6
        // collateralBalance   = 1 ether
        // debtPriceWad        = 1e18
        // collateralPriceWad  = 1000e18
        // liquidationBonusWad = 1.05e18
        // debtDecimals        = 6
        // collateralDecimals  = 18

        // Expected:
        // debtRepaid          = 500e6
        // collateralSeized    = 0.525 ether

        (uint256 debtRepaid, uint256 collateralSeized) = LiquidationMath.calculateAmounts(
            LiquidationMath.QuoteParams({
                debtBudget: 500e6,
                collateralBalance: 1 ether,
                debtPriceWad: 1e18,
                collateralPriceWad: 1000e18,
                liquidationBonusWad: 1.05e18,
                debtDecimals: 6,
                collateralDecimals: 18
            })
        );

        assertEq(debtRepaid, 500e6);
        assertEq(collateralSeized, 0.525 ether);
    }

    function test_liquidation_receivesUnderlying() public {
        _registerMarketContracts();
        _setupWethReserve(); // Bonus must be configured as 1.05e18.
        _setupUsdcReserve();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken wethSupplyToken = ScaledSupplyToken(wethReserve.supplyToken);
        ScaledDebtToken usdcDebtToken = ScaledDebtToken(usdcReserve.debtToken);

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

        // Borrow while WETH is worth $2000.
        vm.prank(alice);
        pool.borrow(address(usdc), 1000e6, alice);

        // WETH falls to $1000. HF becomes 0.8.
        wethFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 2, answer: 1000e8, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 2
            })
        );

        DataTypes.AccountData memory beforeData = pool.getUserAccountData(alice);

        assertEq(beforeData.healthFactorWad, 0.8e18);

        usdc.mint(charlie, 500e6);

        vm.startPrank(charlie);
        usdc.approve(address(pool), 500e6);

        (uint256 debtRepaid, uint256 collateralSeized) =
            pool.liquidationCall(address(weth), address(usdc), alice, 500e6, false);

        vm.stopPrank();

        assertEq(debtRepaid, 500e6);
        assertEq(collateralSeized, 0.525 ether);

        // Liquidator pays USDC and receives underlying WETH.
        assertEq(usdc.balanceOf(charlie), 0);
        assertEq(weth.balanceOf(charlie), 0.525 ether);
        assertEq(wethSupplyToken.balanceOf(charlie), 0);

        // Alice loses collateral and reduces her debt.
        assertEq(usdcDebtToken.balanceOf(alice), 500e6);
        assertEq(wethSupplyToken.balanceOf(alice), 0.475 ether);
        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        // Reserve cash follows the underlying transfers.
        assertEq(pool.availableLiquidity(address(usdc)), 1500e6);
        assertEq(usdc.balanceOf(usdcReserve.supplyToken), 1500e6);

        assertEq(pool.availableLiquidity(address(weth)), 0.475 ether);
        assertEq(weth.balanceOf(wethReserve.supplyToken), 0.475 ether);

        assertEq(pool.totalSupply(address(weth)), 0.475 ether);
        assertEq(pool.totalDebt(address(usdc)), 500e6);

        DataTypes.AccountData memory afterData = pool.getUserAccountData(alice);

        assertEq(afterData.collateralValueWad, 475e18);
        assertEq(afterData.debtValueWad, 500e18);
        assertEq(afterData.liquidationCapacityWad, 380e18);
        assertEq(afterData.availableBorrowsWad, 0);
        assertEq(afterData.healthFactorWad, 0.76e18);
    }

    function test_liquidation_receivesSupplyToken() public {
        _registerMarketContracts();
        _setupWethReserve(); // Bonus must be configured as 1.05e18.
        _setupUsdcReserve();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken wethSupplyToken = ScaledSupplyToken(wethReserve.supplyToken);
        ScaledDebtToken usdcDebtToken = ScaledDebtToken(usdcReserve.debtToken);

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

        // Borrow while WETH is worth $2000.
        vm.prank(alice);
        pool.borrow(address(usdc), 1000e6, alice);

        // WETH falls to $1000. HF becomes 0.8.
        wethFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 2, answer: 1000e8, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 2
            })
        );

        DataTypes.AccountData memory beforeData = pool.getUserAccountData(alice);

        assertEq(beforeData.healthFactorWad, 0.8e18);

        usdc.mint(charlie, 500e6);

        vm.startPrank(charlie);
        usdc.approve(address(pool), 500e6);

        (uint256 debtRepaid, uint256 collateralSeized) =
            pool.liquidationCall(address(weth), address(usdc), alice, 500e6, true);

        vm.stopPrank();

        assertEq(debtRepaid, 500e6);
        assertEq(collateralSeized, 0.525 ether);

        // Liquidator pays USDC and receives aWETH.
        assertEq(usdc.balanceOf(charlie), 0);
        assertEq(weth.balanceOf(charlie), 0);
        assertEq(wethSupplyToken.balanceOf(charlie), 0.525 ether);

        assertFalse(pool.isUsingAsCollateral(charlie, address(weth)));

        // Alice loses collateral and reduces her debt.
        assertEq(usdcDebtToken.balanceOf(alice), 500e6);
        assertEq(wethSupplyToken.balanceOf(alice), 0.475 ether);
        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        // Reserve cash follows the underlying transfers.
        assertEq(pool.availableLiquidity(address(usdc)), 1500e6);
        assertEq(usdc.balanceOf(usdcReserve.supplyToken), 1500e6);

        assertEq(pool.availableLiquidity(address(weth)), 1 ether);
        assertEq(weth.balanceOf(wethReserve.supplyToken), 1 ether);

        assertEq(pool.totalSupply(address(weth)), 1 ether);
        assertEq(pool.totalDebt(address(usdc)), 500e6);

        DataTypes.AccountData memory afterData = pool.getUserAccountData(alice);

        assertEq(afterData.collateralValueWad, 475e18);
        assertEq(afterData.debtValueWad, 500e18);
        assertEq(afterData.liquidationCapacityWad, 380e18);
        assertEq(afterData.availableBorrowsWad, 0);
        assertEq(afterData.healthFactorWad, 0.76e18);
    }

    function test_liquidation_revertsWhenPositionNotLiquidatable() public {
        _registerMarketContracts();
        _setupWethReserve(); // Bonus must be configured as 1.05e18.
        _setupUsdcReserve();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken wethSupplyToken = ScaledSupplyToken(wethReserve.supplyToken);
        ScaledDebtToken usdcDebtToken = ScaledDebtToken(usdcReserve.debtToken);

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

        // Borrow while WETH is worth $2000.
        vm.prank(alice);
        pool.borrow(address(usdc), 1000e6, alice);

        DataTypes.AccountData memory beforeData = pool.getUserAccountData(alice);

        assertEq(beforeData.healthFactorWad, 1.6e18);

        usdc.mint(charlie, 500e6);

        vm.startPrank(charlie);
        usdc.approve(address(pool), 500e6);

        vm.expectRevert(abi.encodeWithSelector(Pool.PositionNotLiquidatable.selector, beforeData.healthFactorWad));
        pool.liquidationCall(address(weth), address(usdc), alice, 500e6, true);

        vm.stopPrank();

        assertEq(usdcDebtToken.balanceOf(alice), 1000e6);
        assertEq(wethSupplyToken.balanceOf(alice), 1 ether);
        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));
    }

    function test_liquidation_closeFactorAboveThreshold() public {
        _registerMarketContracts();
        _setupWethReserve(); // Bonus must be configured as 1.05e18.
        _setupUsdcReserve();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken wethSupplyToken = ScaledSupplyToken(wethReserve.supplyToken);
        ScaledDebtToken usdcDebtToken = ScaledDebtToken(usdcReserve.debtToken);

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

        // Borrow while WETH is worth $2000.
        vm.prank(alice);
        pool.borrow(address(usdc), 1000e6, alice);

        // WETH falls to $1200. HF becomes 0.96.
        wethFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 2, answer: 1200e8, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 2
            })
        );

        DataTypes.AccountData memory beforeData = pool.getUserAccountData(alice);

        assertEq(beforeData.healthFactorWad, 0.96e18);

        usdc.mint(charlie, 1000e6);

        vm.startPrank(charlie);
        usdc.approve(address(pool), 1000e6);

        (uint256 debtRepaid, uint256 collateralSeized) =
            pool.liquidationCall(address(weth), address(usdc), alice, 1000e6, false);

        vm.stopPrank();

        assertEq(debtRepaid, 500e6);
        assertEq(collateralSeized, 0.4375 ether);

        // Liquidator pays USDC and receives underlying WETH.
        assertEq(usdc.balanceOf(charlie), 500e6);
        assertEq(weth.balanceOf(charlie), 0.4375 ether);
        assertEq(wethSupplyToken.balanceOf(charlie), 0);

        // Alice loses collateral and reduces her debt.
        assertEq(usdcDebtToken.balanceOf(alice), 500e6);
        assertEq(wethSupplyToken.balanceOf(alice), 0.5625 ether);
        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        // Reserve cash follows the underlying transfers.
        assertEq(pool.availableLiquidity(address(usdc)), 1500e6);
        assertEq(usdc.balanceOf(usdcReserve.supplyToken), 1500e6);

        assertEq(pool.availableLiquidity(address(weth)), 0.5625 ether);
        assertEq(weth.balanceOf(wethReserve.supplyToken), 0.5625 ether);

        assertEq(pool.totalSupply(address(weth)), 0.5625 ether);
        assertEq(pool.totalDebt(address(usdc)), 500e6);

        DataTypes.AccountData memory afterData = pool.getUserAccountData(alice);

        assertEq(afterData.collateralValueWad, 675e18);
        assertEq(afterData.debtValueWad, 500e18);
        assertEq(afterData.liquidationCapacityWad, 540e18);
        assertEq(afterData.availableBorrowsWad, 6.25e18);
        assertEq(afterData.healthFactorWad, 1.08e18);
    }

    function test_liquidationMath_capsRepaymentByCollateral() public {
        (uint256 debtRepaid, uint256 collateralSeized) = LiquidationMath.calculateAmounts(
            LiquidationMath.QuoteParams({
                debtBudget: 500e6,
                collateralBalance: 0.21 ether,
                debtPriceWad: 1e18,
                collateralPriceWad: 1000e18,
                liquidationBonusWad: 1.05e18,
                debtDecimals: 6,
                collateralDecimals: 18
            })
        );

        assertEq(debtRepaid, 200e6);
        assertEq(collateralSeized, 0.21 ether);
    }

    function test_liquidation_capsRepaymentByAvailableCollateral() public {
        _setupUsdcLoan();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken supplyToken = ScaledSupplyToken(wethReserve.supplyToken);
        ScaledDebtToken debtToken = ScaledDebtToken(usdcReserve.debtToken);

        wethFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 2, answer: 210e8, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 2
            })
        );

        // HF = ($210 × 80%) / $1000 = 0.168.
        assertEq(pool.getUserAccountData(alice).healthFactorWad, 0.168e18);

        usdc.mint(charlie, 500e6);

        vm.startPrank(charlie);
        usdc.approve(address(pool), 500e6);

        (uint256 debtRepaid, uint256 collateralSeized) =
            pool.liquidationCall(address(weth), address(usdc), alice, 500e6, false);

        vm.stopPrank();

        assertEq(debtRepaid, 200e6);
        assertEq(collateralSeized, 1 ether);

        // Only the supported payment is collected.
        assertEq(usdc.balanceOf(charlie), 300e6);
        assertEq(usdc.allowance(charlie, address(pool)), 300e6);
        assertEq(weth.balanceOf(charlie), 1 ether);

        // All selected collateral is exhausted.
        assertEq(supplyToken.scaledBalanceOf(alice), 0);
        assertFalse(pool.isUsingAsCollateral(alice, address(weth)));
        assertEq(pool.availableLiquidity(address(weth)), 0);
        assertEq(weth.balanceOf(wethReserve.supplyToken), 0);

        // Remaining debt is preserved.
        assertEq(debtToken.balanceOf(alice), 800e6);
        assertEq(pool.totalDebt(address(usdc)), 800e6);
        assertEq(pool.availableLiquidity(address(usdc)), 1200e6);
        assertEq(usdc.balanceOf(usdcReserve.supplyToken), 1200e6);
    }

    function test_liquidation_revertsWhenPositionNotLiquidatable_hf1() public {
        _setupUsdcLoan();

        wethFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 2, answer: 1250e8, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 2
            })
        );

        // HF = (1 × $1250 × 80%) / $1000 = 1
        assertEq(pool.getUserAccountData(alice).healthFactorWad, 1e18);

        usdc.mint(charlie, 500e6);

        vm.startPrank(charlie);
        usdc.approve(address(pool), 500e6);

        vm.expectRevert(abi.encodeWithSelector(Pool.PositionNotLiquidatable.selector, 1e18));

        pool.liquidationCall(address(weth), address(usdc), alice, 500e6, false);

        vm.stopPrank();
    }

    function test_liquidation_afterYear_usesAccruedDebt() public {
        // Supplies 1 WETH, supplies 2000 USDC and borrows 1000 USDC.
        _setupUsdcLoan();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken wethSupplyToken = ScaledSupplyToken(wethReserve.supplyToken);
        ScaledSupplyToken usdcSupplyToken = ScaledSupplyToken(usdcReserve.supplyToken);
        ScaledDebtToken usdcDebtToken = ScaledDebtToken(usdcReserve.debtToken);

        skip(365 days);

        // Refresh both feeds and lower the collateral price.
        wethFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 2, answer: 1200e8, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 2
            })
        );

        usdcFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 2, answer: 1e8, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 2
            })
        );

        assertEq(pool.currentBorrowIndex(address(usdc)), 1.045e18);
        assertEq(pool.currentLiquidityIndex(address(usdc)), 1.02025e18);
        assertEq(usdcDebtToken.scaledBalanceOf(alice), 1000e6);
        assertEq(usdcDebtToken.balanceOf(alice), 1045e6);
        assertEq(usdcSupplyToken.balanceOf(bob), 2040.5e6);

        DataTypes.AccountData memory beforeData = pool.getUserAccountData(alice);

        assertEq(beforeData.healthFactorWad, Math.mulDiv(960e18, DecimalMath.WAD, 1045e18, Math.Rounding.Floor));
        assertLt(beforeData.healthFactorWad, 0.95e18);

        usdc.mint(charlie, 500e6);

        vm.startPrank(charlie);
        usdc.approve(address(pool), 500e6);

        (uint256 debtRepaid, uint256 collateralSeized) =
            pool.liquidationCall(address(weth), address(usdc), alice, 500e6, false);

        vm.stopPrank();

        assertEq(debtRepaid, 500e6);
        assertEq(collateralSeized, 0.4375 ether);

        assertEq(usdc.balanceOf(charlie), 0);
        assertEq(weth.balanceOf(charlie), 0.4375 ether);

        // floor(500e6 / 1.045) = 478_468_899 shares burned.
        assertEq(usdcDebtToken.scaledBalanceOf(alice), 521_531_101);
        assertEq(usdcDebtToken.balanceOf(alice), 545_000_001);
        assertEq(pool.totalDebt(address(usdc)), 545_000_001);

        assertEq(wethSupplyToken.balanceOf(alice), 0.5625 ether);
        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        assertEq(pool.availableLiquidity(address(usdc)), 1500e6);
        assertEq(usdc.balanceOf(usdcReserve.supplyToken), 1500e6);

        assertEq(pool.availableLiquidity(address(weth)), 0.5625 ether);
        assertEq(weth.balanceOf(wethReserve.supplyToken), 0.5625 ether);

        // Liquidation commits accrued interest before reducing debt.
        usdcReserve = pool.getReserveData(address(usdc));

        assertEq(usdcReserve.state.borrowIndex, 1.045e18);
        assertEq(usdcReserve.state.liquidityIndex, 1.02025e18);
        assertEq(usdcReserve.state.accruedToTreasury, 4.5e6);
        assertEq(usdcReserve.state.lastUpdateTimestamp, block.timestamp);

        // Collateral:            0.5625 WETH × $1200 = $675
        // Debt:                  545.000001 USDC
        // Liquidation capacity:  $540
        // HF:                    ≈ 0.990825686

        DataTypes.AccountData memory afterData = pool.getUserAccountData(alice);

        assertEq(afterData.collateralValueWad, 675e18);
        assertEq(afterData.debtValueWad, 545_000_001 * 1e12);
        assertEq(afterData.liquidationCapacityWad, 540e18);
        assertEq(afterData.availableBorrowsWad, 0);
        assertEq(
            afterData.healthFactorWad, Math.mulDiv(540e18, DecimalMath.WAD, 545_000_001 * 1e12, Math.Rounding.Floor)
        ); //~ 0.9908e18

        // Collateral seized = $100 × 1.05 / $1200 = 0.0875 WETH

        // Remaining collateral = 0.475 WETH = $570
        // Remaining debt       ≈ 445.000002 USDC
        // Liquidation capacity = $456
        // HF                   ≈ 1.024719

        usdc.mint(charlie, 100e6);

        vm.startPrank(charlie);
        usdc.approve(address(pool), 100e6);

        (debtRepaid, collateralSeized) = pool.liquidationCall(address(weth), address(usdc), alice, 100e6, false);

        vm.stopPrank();

        assertEq(debtRepaid, 100e6);
        assertEq(collateralSeized, 0.0875 ether);

        assertEq(usdc.balanceOf(charlie), 0);
        assertEq(weth.balanceOf(charlie), 0.525 ether);

        afterData = pool.getUserAccountData(alice);

        assertEq(afterData.collateralValueWad, 570e18);
        assertEq(afterData.debtValueWad, 445_000_002 * 1e12);
        assertEq(afterData.liquidationCapacityWad, 456e18);
        assertEq(afterData.availableBorrowsWad, 0);
        assertEq(
            afterData.healthFactorWad, Math.mulDiv(456e18, DecimalMath.WAD, 445_000_002 * 1e12, Math.Rounding.Floor)
        ); // ~1.024719096518116420

        assertGt(afterData.healthFactorWad, DecimalMath.WAD);

        vm.expectRevert(abi.encodeWithSelector(Pool.PositionNotLiquidatable.selector, afterData.healthFactorWad));
        vm.prank(charlie);
        pool.liquidationCall(address(weth), address(usdc), alice, 100e6, false);
    }

    function test_liquidation_receivesUnderlyingAtRaisedLiquidityIndex() public {
        _registerMarketContracts();
        _setupWethReserve(); // Bonus must be configured as 1.05e18.
        _setupUsdcReserve();

        pool.setLiquidityIndexForTest(address(weth), 1.25e18);

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken wethSupplyToken = ScaledSupplyToken(wethReserve.supplyToken);
        ScaledDebtToken usdcDebtToken = ScaledDebtToken(usdcReserve.debtToken);

        assertEq(wethReserve.state.liquidityIndex, 1.25e18);

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

        assertEq(wethSupplyToken.scaledBalanceOf(alice), 0.8e18);
        assertEq(wethSupplyToken.scaledTotalSupply(), 0.8e18);

        // Borrow while WETH is worth $2000.
        vm.prank(alice);
        pool.borrow(address(usdc), 1000e6, alice);

        // WETH falls to $1000. HF becomes 0.8.
        wethFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 2, answer: 1000e8, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 2
            })
        );

        DataTypes.AccountData memory beforeData = pool.getUserAccountData(alice);

        assertEq(beforeData.healthFactorWad, 0.8e18);

        usdc.mint(charlie, 500e6);

        vm.startPrank(charlie);
        usdc.approve(address(pool), 500e6);

        (uint256 debtRepaid, uint256 collateralSeized) =
            pool.liquidationCall(address(weth), address(usdc), alice, 500e6, false);

        vm.stopPrank();

        assertEq(debtRepaid, 500e6);
        assertEq(collateralSeized, 0.525 ether);

        assertEq(wethSupplyToken.scaledBalanceOf(alice), 0.38e18);
        assertEq(wethSupplyToken.scaledTotalSupply(), 0.38e18);
        assertEq(pool.currentLiquidityIndex(address(weth)), 1.25e18);

        // Liquidator pays USDC and receives underlying WETH.
        assertEq(usdc.balanceOf(charlie), 0);
        assertEq(weth.balanceOf(charlie), 0.525 ether);
        assertEq(wethSupplyToken.balanceOf(charlie), 0);

        // // Alice loses collateral and reduces her debt.
        assertEq(usdcDebtToken.balanceOf(alice), 500e6);
        assertEq(wethSupplyToken.balanceOf(alice), 0.475 ether);
        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        // Reserve cash follows the underlying transfers.
        assertEq(pool.availableLiquidity(address(usdc)), 1500e6);
        assertEq(usdc.balanceOf(usdcReserve.supplyToken), 1500e6);

        assertEq(pool.availableLiquidity(address(weth)), 0.475 ether);
        assertEq(weth.balanceOf(wethReserve.supplyToken), 0.475 ether);

        assertEq(pool.totalSupply(address(weth)), 0.475 ether);
        assertEq(pool.totalDebt(address(usdc)), 500e6);

        DataTypes.AccountData memory afterData = pool.getUserAccountData(alice);

        assertEq(afterData.collateralValueWad, 475e18);
        assertEq(afterData.debtValueWad, 500e18);
        assertEq(afterData.liquidationCapacityWad, 380e18);
        assertEq(afterData.availableBorrowsWad, 0);
        assertEq(afterData.healthFactorWad, 0.76e18);
    }
}
