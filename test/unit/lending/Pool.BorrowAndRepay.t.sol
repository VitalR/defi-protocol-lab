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

contract PoolBorrowAndRepayTest is Test {
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

    function test_borrow_usdcAgainstWeth() public {
        _registerMarketContracts();
        _setupWethReserve();
        _setupUsdcReserve();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken usdcSupplyToken = ScaledSupplyToken(usdcReserve.supplyToken);
        ScaledDebtToken usdcDebtToken = ScaledDebtToken(usdcReserve.debtToken);

        // Alice supplies collateral.
        weth.mint(alice, 1 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        pool.supply(address(weth), 1 ether, alice);
        pool.setUserUseReserveAsCollateral(address(weth), true);
        vm.stopPrank();

        // Bob funds the USDC reserve.
        usdc.mint(bob, 2000e6);

        vm.startPrank(bob);
        usdc.approve(address(pool), 2000e6);
        pool.supply(address(usdc), 2000e6, bob);
        vm.stopPrank();

        // Indexes are WAD: actual and scaled debt match.
        assertEq(pool.currentBorrowIndex(address(usdc)), DecimalMath.WAD);
        assertEq(pool.availableLiquidity(address(usdc)), 2000e6);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdcDebtToken.balanceOf(alice), 0);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Borrowed(address(usdc), alice, alice, 1000e6, 1000e6);

        vm.prank(alice);
        pool.borrow(address(usdc), 1000e6, alice);

        // Underlying movement.
        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(usdc.balanceOf(address(usdcSupplyToken)), 1000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);

        // Debt belongs to Alice.
        assertEq(usdcDebtToken.scaledBalanceOf(alice), 1000e6);
        assertEq(usdcDebtToken.balanceOf(alice), 1000e6);
        assertEq(usdcDebtToken.balanceOf(bob), 0);
        assertEq(pool.totalScaledDebt(address(usdc)), 1000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);

        // Bob's supplier claim remains intact.
        assertEq(usdcSupplyToken.scaledBalanceOf(bob), 2000e6);
        assertEq(usdcSupplyToken.balanceOf(bob), 2000e6);
        assertEq(pool.totalSupply(address(usdc)), 2000e6);

        // Collateral remains in the WETH reserve.
        assertEq(weth.balanceOf(wethReserve.supplyToken), 1 ether);
        assertEq(ScaledSupplyToken(wethReserve.supplyToken).balanceOf(alice), 1 ether);
        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        // Risk data includes the newly created debt.
        DataTypes.AccountData memory data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 2000e18);
        assertEq(data.debtValueWad, 1000e18);
        assertEq(data.borrowCapacityWad, 1500e18);
        assertEq(data.liquidationCapacityWad, 1600e18);
        assertEq(data.availableBorrowsWad, 500e18);
        assertEq(data.healthFactorWad, 1.6e18);

        // New rates apply to the interval after borrowing.
        usdcReserve = pool.getReserveData(address(usdc));

        assertEq(pool.utilization(address(usdc)), 0.5e18);
        assertEq(usdcReserve.state.currentBorrowRate, 0.045e18);
        assertEq(usdcReserve.state.currentLiquidityRate, 0.02025e18);

        // No elapsed time means no accrued interest yet.
        assertEq(usdcReserve.state.accruedToTreasury, 0);
        assertEq(usdcReserve.state.lastUpdateTimestamp, block.timestamp);
    }

    function test_borrow_usdcAgainstWeth_delegateBorrow() public {
        _registerMarketContracts();
        _setupWethReserve();
        _setupUsdcReserve();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken usdcSupplyToken = ScaledSupplyToken(usdcReserve.supplyToken);
        ScaledDebtToken usdcDebtToken = ScaledDebtToken(usdcReserve.debtToken);

        // Alice supplies collateral.
        weth.mint(alice, 1 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        pool.supply(address(weth), 1 ether, alice);
        pool.setUserUseReserveAsCollateral(address(weth), true);
        vm.stopPrank();

        // Bob funds the USDC reserve.
        usdc.mint(bob, 2000e6);

        vm.startPrank(bob);
        usdc.approve(address(pool), 2000e6);
        pool.supply(address(usdc), 2000e6, bob);
        vm.stopPrank();

        // Indexes are WAD: actual and scaled debt match.
        assertEq(pool.currentBorrowIndex(address(usdc)), DecimalMath.WAD);
        assertEq(pool.availableLiquidity(address(usdc)), 2000e6);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdcDebtToken.balanceOf(alice), 0);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(usdcDebtToken));
        emit BorrowAllowanceDelegated(alice, charlie, address(usdc), 1000e6);
        usdcDebtToken.approveDelegation(charlie, 1000e6);

        assertEq(usdcDebtToken.borrowAllowance(alice, charlie), 1000e6);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Borrowed(address(usdc), charlie, alice, 1000e6, 1000e6);

        vm.prank(charlie);
        pool.borrow(address(usdc), 1000e6, alice);

        assertEq(usdcDebtToken.borrowAllowance(alice, charlie), 0);
        assertEq(usdcDebtToken.balanceOf(charlie), 0);

        // Underlying movement.
        assertEq(usdc.balanceOf(charlie), 1000e6);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(usdc.balanceOf(address(usdcSupplyToken)), 1000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);

        // Debt belongs to Alice.
        assertEq(usdcDebtToken.scaledBalanceOf(alice), 1000e6);
        assertEq(usdcDebtToken.balanceOf(alice), 1000e6);
        assertEq(usdcDebtToken.balanceOf(bob), 0);
        assertEq(pool.totalScaledDebt(address(usdc)), 1000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);

        // Bob's supplier claim remains intact.
        assertEq(usdcSupplyToken.scaledBalanceOf(bob), 2000e6);
        assertEq(usdcSupplyToken.balanceOf(bob), 2000e6);
        assertEq(pool.totalSupply(address(usdc)), 2000e6);

        // Collateral remains in the WETH reserve.
        assertEq(weth.balanceOf(wethReserve.supplyToken), 1 ether);
        assertEq(ScaledSupplyToken(wethReserve.supplyToken).balanceOf(alice), 1 ether);
        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        // Risk data includes the newly created debt.
        DataTypes.AccountData memory data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 2000e18);
        assertEq(data.debtValueWad, 1000e18);
        assertEq(data.borrowCapacityWad, 1500e18);
        assertEq(data.liquidationCapacityWad, 1600e18);
        assertEq(data.availableBorrowsWad, 500e18);
        assertEq(data.healthFactorWad, 1.6e18);

        data = pool.getUserAccountData(charlie);

        assertEq(data.collateralValueWad, 0e18);
        assertEq(data.debtValueWad, 0e18);
        assertEq(data.borrowCapacityWad, 0e18);
        assertEq(data.liquidationCapacityWad, 0e18);
        assertEq(data.availableBorrowsWad, 0e18);
        assertEq(data.healthFactorWad, type(uint256).max);

        // New rates apply to the interval after borrowing.
        usdcReserve = pool.getReserveData(address(usdc));

        assertEq(pool.utilization(address(usdc)), 0.5e18);
        assertEq(usdcReserve.state.currentBorrowRate, 0.045e18);
        assertEq(usdcReserve.state.currentLiquidityRate, 0.02025e18);

        // No elapsed time means no accrued interest yet.
        assertEq(usdcReserve.state.accruedToTreasury, 0);
        assertEq(usdcReserve.state.lastUpdateTimestamp, block.timestamp);
    }

    function test_borrow_reverts() public {
        vm.prank(alice);
        vm.expectRevert(Pool.ZeroAddress.selector);
        pool.borrow(address(0), 1000e6, alice);

        vm.prank(alice);
        vm.expectRevert(Pool.ZeroAddress.selector);
        pool.borrow(alice, 1000e6, address(0));

        vm.prank(alice);
        vm.expectRevert(Pool.ZeroAmount.selector);
        pool.borrow(alice, 0, alice);
    }

    function test_borrow_usdcAgainstWeth_revertsWhenInsufficientBorrowAllowance() public {
        _registerMarketContracts();
        _setupWethReserve();
        _setupUsdcReserve();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken usdcSupplyToken = ScaledSupplyToken(usdcReserve.supplyToken);
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

        assertEq(pool.currentBorrowIndex(address(usdc)), DecimalMath.WAD);
        assertEq(pool.availableLiquidity(address(usdc)), 2000e6);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdcDebtToken.balanceOf(alice), 0);

        assertEq(usdcDebtToken.borrowAllowance(alice, charlie), 0e6);

        vm.prank(charlie);
        vm.expectRevert(
            abi.encodeWithSelector(ScaledDebtToken.InsufficientBorrowAllowance.selector, alice, charlie, 1000e6, 0)
        );
        pool.borrow(address(usdc), 1000e6, alice);

        assertEq(usdcDebtToken.balanceOf(charlie), 0);
        assertEq(usdcDebtToken.scaledBalanceOf(alice), 0);
        assertEq(pool.totalScaledDebt(address(usdc)), 0);

        assertEq(pool.availableLiquidity(address(usdc)), 2000e6);
        assertEq(usdc.balanceOf(address(usdcSupplyToken)), 2000e6);
        assertEq(usdc.balanceOf(charlie), 0);
    }

    function test_borrow_usdcAgainstWeth_revertsWhenBorrowExceedsCapacity() public {
        _registerMarketContracts();
        _setupWethReserve();
        _setupUsdcReserve();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken usdcSupplyToken = ScaledSupplyToken(usdcReserve.supplyToken);
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

        assertEq(pool.currentBorrowIndex(address(usdc)), DecimalMath.WAD);
        assertEq(pool.availableLiquidity(address(usdc)), 2000e6);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdcDebtToken.balanceOf(alice), 0);

        vm.prank(alice);
        usdcDebtToken.approveDelegation(charlie, 2000e6);

        assertEq(usdcDebtToken.borrowAllowance(alice, charlie), 2000e6);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(Pool.BorrowExceedsCapacity.selector, 1501e18, 1500e18));
        pool.borrow(address(usdc), 1501e6, alice);

        assertEq(usdcDebtToken.borrowAllowance(alice, charlie), 2000e6);
        assertEq(usdcDebtToken.balanceOf(charlie), 0);
    }

    function test_finalizeTransfer() public {
        _registerMarketContracts();
        _setupWethReserve();
        _setupUsdcReserve();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken wethSupplyToken = ScaledSupplyToken(wethReserve.supplyToken);
        ScaledSupplyToken usdcSupplyToken = ScaledSupplyToken(usdcReserve.supplyToken);
        ScaledDebtToken usdcDebtToken = ScaledDebtToken(usdcReserve.debtToken);

        // Alice supplies collateral.
        weth.mint(alice, 1 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        pool.supply(address(weth), 1 ether, alice);
        pool.setUserUseReserveAsCollateral(address(weth), true);
        vm.stopPrank();

        // Bob funds the USDC reserve.
        usdc.mint(bob, 2000e6);

        vm.startPrank(bob);
        usdc.approve(address(pool), 2000e6);
        pool.supply(address(usdc), 2000e6, bob);
        vm.stopPrank();

        // Indexes are WAD: actual and scaled debt match.
        assertEq(pool.currentBorrowIndex(address(usdc)), DecimalMath.WAD);
        assertEq(pool.availableLiquidity(address(usdc)), 2000e6);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdcDebtToken.balanceOf(alice), 0);

        vm.prank(alice);
        pool.borrow(address(usdc), 1000e6, alice);

        // Underlying movement.
        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(usdc.balanceOf(address(usdcSupplyToken)), 1000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);

        // aWETH movement.
        assertEq(wethSupplyToken.balanceOf(alice), 1 ether);
        assertEq(wethSupplyToken.balanceOf(bob), 0);

        // Risk data includes the newly created debt.
        DataTypes.AccountData memory data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 2000e18);
        assertEq(data.debtValueWad, 1000e18);
        assertEq(data.borrowCapacityWad, 1500e18);
        assertEq(data.liquidationCapacityWad, 1600e18);
        assertEq(data.availableBorrowsWad, 500e18);
        assertEq(data.healthFactorWad, 1.6e18);

        vm.prank(alice);
        wethSupplyToken.transfer(bob, 0.3 ether); //0.3 aWETH

        assertEq(wethSupplyToken.balanceOf(alice), 0.7 ether);
        assertEq(wethSupplyToken.balanceOf(bob), 0.3 ether);

        data = pool.getUserAccountData(alice);

        assertEq(data.liquidationCapacityWad, 1120e18);

        vm.prank(alice);
        wethSupplyToken.approve(bob, 0.3 ether);
        assertEq(wethSupplyToken.allowance(alice, bob), 0.3 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Pool.InsufficientCollateral.selector, 1000e18, 640e18));
        wethSupplyToken.transferFrom(alice, bob, 0.3 ether);

        assertEq(wethSupplyToken.allowance(alice, bob), 0.3 ether);

        assertEq(wethSupplyToken.balanceOf(alice), 0.7 ether);
        assertEq(wethSupplyToken.balanceOf(bob), 0.3 ether);

        data = pool.getUserAccountData(alice);
        assertEq(data.collateralValueWad, 1400e18);
        assertEq(data.debtValueWad, 1000e18);
        assertEq(data.borrowCapacityWad, 1050e18);
        assertEq(data.liquidationCapacityWad, 1120e18);
        assertEq(data.availableBorrowsWad, 50e18);
        assertEq(data.healthFactorWad, 1.12e18);

        assertFalse(pool.isUsingAsCollateral(bob, address(weth)));

        data = pool.getUserAccountData(bob);
        assertEq(data.collateralValueWad, 0e18);
        assertEq(data.debtValueWad, 0e18);
        assertEq(data.borrowCapacityWad, 0e18);
        assertEq(data.liquidationCapacityWad, 0e18);
        assertEq(data.availableBorrowsWad, 0e18);
        assertEq(data.healthFactorWad, type(uint256).max);
    }

    function test_finalizeTransfer_reverts() public {
        _registerMarketContracts();
        _setupWethReserve();
        _setupUsdcReserve();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        ScaledSupplyToken wethSupplyToken = ScaledSupplyToken(wethReserve.supplyToken);

        vm.expectRevert(abi.encodeWithSelector(Pool.OnlySupplyToken.selector, address(this)));
        pool.finalizeTransfer(address(weth), alice, bob);

        vm.expectRevert(abi.encodeWithSelector(Pool.UnsupportedAsset.selector, address(wethSupplyToken)));
        pool.finalizeTransfer(address(wethSupplyToken), alice, bob);

        vm.prank(alice);
        wethSupplyToken.approve(bob, 0.3 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyToken.InvalidRecipient.selector, address(0)));
        wethSupplyToken.transferFrom(alice, address(0), 0.3 ether);
    }

    function test_transfer_fullWithoutDebt_clearsSenderCollateral() public {
        _registerMarketContracts();
        _setupWethReserve();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));

        ScaledSupplyToken supplyToken = ScaledSupplyToken(reserve.supplyToken);

        weth.mint(alice, 1 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        pool.supply(address(weth), 1 ether, alice);
        pool.setUserUseReserveAsCollateral(address(weth), true);
        vm.stopPrank();

        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));
        assertFalse(pool.isUsingAsCollateral(bob, address(weth)));

        vm.prank(alice);
        supplyToken.transfer(bob, 1 ether);

        assertEq(supplyToken.scaledBalanceOf(alice), 0);
        assertEq(supplyToken.balanceOf(bob), 1 ether);

        assertFalse(pool.isUsingAsCollateral(alice, address(weth)));
        assertFalse(pool.isUsingAsCollateral(bob, address(weth)));

        // Transfer moves the supplier claim; underlying stays in custody.
        assertEq(weth.balanceOf(address(supplyToken)), 1 ether);
        assertEq(pool.availableLiquidity(address(weth)), 1 ether);
        assertEq(pool.totalSupply(address(weth)), 1 ether);

        vm.prank(bob);
        pool.setUserUseReserveAsCollateral(address(weth), true);

        assertTrue(pool.isUsingAsCollateral(bob, address(weth)));
    }

    function test_repay() public {
        _registerMarketContracts();
        _setupWethReserve();
        _setupUsdcReserve();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken usdcSupplyToken = ScaledSupplyToken(usdcReserve.supplyToken);
        ScaledDebtToken usdcDebtToken = ScaledDebtToken(usdcReserve.debtToken);

        // Alice supplies collateral.
        weth.mint(alice, 1 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        pool.supply(address(weth), 1 ether, alice);
        pool.setUserUseReserveAsCollateral(address(weth), true);
        vm.stopPrank();

        // Bob funds the USDC reserve.
        usdc.mint(bob, 2000e6);

        vm.startPrank(bob);
        usdc.approve(address(pool), 2000e6);
        pool.supply(address(usdc), 2000e6, bob);
        vm.stopPrank();

        // Indexes are WAD: actual and scaled debt match.
        assertEq(pool.currentBorrowIndex(address(usdc)), DecimalMath.WAD);
        assertEq(pool.availableLiquidity(address(usdc)), 2000e6);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdcDebtToken.balanceOf(alice), 0);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Borrowed(address(usdc), alice, alice, 1000e6, 1000e6);

        vm.prank(alice);
        pool.borrow(address(usdc), 1000e6, alice);

        // Underlying movement.
        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(usdc.balanceOf(address(usdcSupplyToken)), 1000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);

        // Debt belongs to Alice.
        assertEq(usdcDebtToken.scaledBalanceOf(alice), 1000e6);
        assertEq(usdcDebtToken.balanceOf(alice), 1000e6);
        assertEq(usdcDebtToken.balanceOf(bob), 0);
        assertEq(pool.totalScaledDebt(address(usdc)), 1000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);

        // Bob's supplier claim remains intact.
        assertEq(usdcSupplyToken.scaledBalanceOf(bob), 2000e6);
        assertEq(usdcSupplyToken.balanceOf(bob), 2000e6);
        assertEq(pool.totalSupply(address(usdc)), 2000e6);

        // Collateral remains in the WETH reserve.
        assertEq(weth.balanceOf(wethReserve.supplyToken), 1 ether);
        assertEq(ScaledSupplyToken(wethReserve.supplyToken).balanceOf(alice), 1 ether);
        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        // Risk data includes the newly created debt.
        DataTypes.AccountData memory data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 2000e18);
        assertEq(data.debtValueWad, 1000e18);
        assertEq(data.borrowCapacityWad, 1500e18);
        assertEq(data.liquidationCapacityWad, 1600e18);
        assertEq(data.availableBorrowsWad, 500e18);
        assertEq(data.healthFactorWad, 1.6e18);

        // New rates apply to the interval after borrowing.
        usdcReserve = pool.getReserveData(address(usdc));

        assertEq(pool.utilization(address(usdc)), 0.5e18);
        assertEq(usdcReserve.state.currentBorrowRate, 0.045e18);
        assertEq(usdcReserve.state.currentLiquidityRate, 0.02025e18);

        // No elapsed time means no accrued interest yet.
        assertEq(usdcReserve.state.accruedToTreasury, 0);
        assertEq(usdcReserve.state.lastUpdateTimestamp, block.timestamp);

        vm.startPrank(alice);
        usdc.approve(address(pool), 400e6);
        vm.expectEmit(true, true, true, true, address(pool));
        emit Repaid(address(usdc), alice, alice, 400e6, 400e6);
        uint256 repaid = pool.repay(address(usdc), 400e6, alice);

        assertEq(repaid, 400e6);

        assertEq(usdc.balanceOf(alice), 600e6);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(usdc.balanceOf(address(usdcSupplyToken)), 1400e6);
        assertEq(pool.availableLiquidity(address(usdc)), 1400e6);

        // Debt belongs to Alice.
        assertEq(usdcDebtToken.scaledBalanceOf(alice), 600e6);
        assertEq(usdcDebtToken.balanceOf(alice), 600e6);
        assertEq(usdcDebtToken.balanceOf(bob), 0);
        assertEq(pool.totalScaledDebt(address(usdc)), 600e6);
        assertEq(pool.totalDebt(address(usdc)), 600e6);

        // debt = 600, cash = 1400, utilization = 30%.
        usdcReserve = pool.getReserveData(address(usdc));

        assertEq(pool.utilization(address(usdc)), 0.3e18);
        assertEq(usdcReserve.state.currentBorrowRate, 0.035e18);
        assertEq(usdcReserve.state.currentLiquidityRate, 0.00945e18);

        data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 2000e18);
        assertEq(data.debtValueWad, 600e18);
        assertEq(data.borrowCapacityWad, 1500e18);
        assertEq(data.liquidationCapacityWad, 1600e18);
        assertEq(data.availableBorrowsWad, 900e18);
        assertEq(data.healthFactorWad, 2_666_666_666_666_666_666);

        // full repay
        usdc.approve(address(pool), 600e6);
        vm.expectEmit(true, true, true, true, address(pool));
        emit Repaid(address(usdc), alice, alice, 600e6, 600e6);
        repaid = pool.repay(address(usdc), 600e6, alice);
        vm.stopPrank();

        assertEq(repaid, 600e6);

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(usdc.balanceOf(address(usdcSupplyToken)), 2000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 2000e6);

        // Debt belongs to Alice.
        assertEq(usdcDebtToken.scaledBalanceOf(alice), 0e6);
        assertEq(usdcDebtToken.balanceOf(alice), 0e6);
        assertEq(usdcDebtToken.balanceOf(bob), 0);
        assertEq(pool.totalScaledDebt(address(usdc)), 0e6);
        assertEq(pool.totalDebt(address(usdc)), 0e6);

        usdcReserve = pool.getReserveData(address(usdc));

        assertEq(pool.utilization(address(usdc)), 0);
        assertEq(usdcReserve.state.currentBorrowRate, pool.BASE_RATE());
        assertEq(usdcReserve.state.currentLiquidityRate, 0);

        assertEq(usdcSupplyToken.balanceOf(bob), 2000e6);
        assertEq(usdcReserve.state.accruedToTreasury, 0);

        data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 2000e18);
        assertEq(data.debtValueWad, 0e18);
        assertEq(data.borrowCapacityWad, 1500e18);
        assertEq(data.liquidationCapacityWad, 1600e18);
        assertEq(data.availableBorrowsWad, 1500e18);
        assertEq(data.healthFactorWad, type(uint256).max);
    }

    function test_repay_fullRepayAfterOneYear() public {
        _registerMarketContracts();
        _setupWethReserve();
        _setupUsdcReserve();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken usdcSupplyToken = ScaledSupplyToken(usdcReserve.supplyToken);
        ScaledDebtToken usdcDebtToken = ScaledDebtToken(usdcReserve.debtToken);

        // Alice supplies collateral.
        weth.mint(alice, 1 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        pool.supply(address(weth), 1 ether, alice);
        pool.setUserUseReserveAsCollateral(address(weth), true);
        vm.stopPrank();

        // Bob funds the USDC reserve.
        usdc.mint(bob, 2000e6);

        vm.startPrank(bob);
        usdc.approve(address(pool), 2000e6);
        pool.supply(address(usdc), 2000e6, bob);
        vm.stopPrank();

        // Indexes are WAD: actual and scaled debt match.
        assertEq(pool.currentBorrowIndex(address(usdc)), DecimalMath.WAD);
        assertEq(pool.availableLiquidity(address(usdc)), 2000e6);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdcDebtToken.balanceOf(alice), 0);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Borrowed(address(usdc), alice, alice, 1000e6, 1000e6);

        vm.prank(alice);
        pool.borrow(address(usdc), 1000e6, alice);

        // Underlying movement.
        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(usdc.balanceOf(address(usdcSupplyToken)), 1000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);

        // Debt belongs to Alice.
        assertEq(usdcDebtToken.scaledBalanceOf(alice), 1000e6);
        assertEq(usdcDebtToken.balanceOf(alice), 1000e6);
        assertEq(usdcDebtToken.balanceOf(bob), 0);
        assertEq(pool.totalScaledDebt(address(usdc)), 1000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);

        // Bob's supplier claim remains intact.
        assertEq(usdcSupplyToken.scaledBalanceOf(bob), 2000e6);
        assertEq(usdcSupplyToken.balanceOf(bob), 2000e6);
        assertEq(pool.totalSupply(address(usdc)), 2000e6);

        // Collateral remains in the WETH reserve.
        assertEq(weth.balanceOf(wethReserve.supplyToken), 1 ether);
        assertEq(ScaledSupplyToken(wethReserve.supplyToken).balanceOf(alice), 1 ether);
        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        // Risk data includes the newly created debt.
        DataTypes.AccountData memory data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 2000e18);
        assertEq(data.debtValueWad, 1000e18);
        assertEq(data.borrowCapacityWad, 1500e18);
        assertEq(data.liquidationCapacityWad, 1600e18);
        assertEq(data.availableBorrowsWad, 500e18);
        assertEq(data.healthFactorWad, 1.6e18);

        // New rates apply to the interval after borrowing.
        usdcReserve = pool.getReserveData(address(usdc));

        assertEq(pool.utilization(address(usdc)), 0.5e18);
        assertEq(usdcReserve.state.currentBorrowRate, 0.045e18);
        assertEq(usdcReserve.state.currentLiquidityRate, 0.02025e18);

        // No elapsed time means no accrued interest yet.
        assertEq(usdcReserve.state.accruedToTreasury, 0);
        assertEq(usdcReserve.state.lastUpdateTimestamp, block.timestamp);

        skip(365 days);

        wethFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 2, answer: 2000e8, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 2
            })
        );

        usdcFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 2, answer: 1e8, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 2
            })
        );

        // Views include interest without updating stored reserve state.
        assertEq(pool.currentBorrowIndex(address(usdc)), 1.045e18);
        assertEq(pool.currentLiquidityIndex(address(usdc)), 1.02025e18);

        assertEq(usdcDebtToken.scaledBalanceOf(alice), 1000e6);
        assertEq(usdcDebtToken.balanceOf(alice), 1045e6);

        assertEq(usdcSupplyToken.scaledBalanceOf(bob), 2000e6);
        assertEq(usdcSupplyToken.balanceOf(bob), 2040.5e6);

        // Interest increases receivables, not cash.
        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);

        data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 2000e18);
        assertEq(data.debtValueWad, 1045e18);
        assertEq(data.borrowCapacityWad, 1500e18);
        assertEq(data.liquidationCapacityWad, 1600e18);
        assertEq(data.availableBorrowsWad, 455e18);
        assertEq(data.healthFactorWad, Math.mulDiv(1600e18, DecimalMath.WAD, 1045e18, Math.Rounding.Floor));

        // Stored state has not been accrued by these view calls.
        DataTypes.ReserveData memory beforeRepay = pool.getReserveData(address(usdc));

        assertEq(beforeRepay.state.borrowIndex, DecimalMath.WAD);
        assertEq(beforeRepay.state.liquidityIndex, DecimalMath.WAD);
        assertEq(beforeRepay.state.accruedToTreasury, 0);
        assertEq(beforeRepay.state.lastUpdateTimestamp, block.timestamp - 365 days);

        // Utilization uses current debt: it has increased above 50%.
        assertEq(pool.utilization(address(usdc)), Math.mulDiv(1045e6, DecimalMath.WAD, 2045e6, Math.Rounding.Floor));

        // Alice already holds the borrowed 1000 USDC.
        // Fund the additional interest.
        usdc.mint(alice, 45e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1045e6);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Repaid(address(usdc), alice, alice, 1045e6, 1000e6);

        uint256 repaid = pool.repay(address(usdc), type(uint256).max, alice);

        vm.stopPrank();

        assertEq(repaid, 1045e6);
        assertEq(usdc.balanceOf(alice), 0);

        assertEq(usdcDebtToken.scaledBalanceOf(alice), 0);
        assertEq(pool.totalDebt(address(usdc)), 0);

        // 2045 USDC cash = 2040.5 supplier claim + 4.5 treasury accrual
        assertEq(pool.availableLiquidity(address(usdc)), 2045e6);
        assertEq(usdc.balanceOf(address(usdcSupplyToken)), 2045e6);
        assertEq(usdcSupplyToken.balanceOf(bob), 2040.5e6);

        usdcReserve = pool.getReserveData(address(usdc));

        assertEq(usdcReserve.state.borrowIndex, 1.045e18);
        assertEq(usdcReserve.state.liquidityIndex, 1.02025e18);
        assertEq(usdcReserve.state.accruedToTreasury, 4.5e6);
        assertEq(usdcReserve.state.lastUpdateTimestamp, block.timestamp);

        assertEq(usdcReserve.state.currentBorrowRate, pool.BASE_RATE());
        assertEq(usdcReserve.state.currentLiquidityRate, 0);
        assertEq(pool.utilization(address(usdc)), 0);
    }

    function test_repay_onBehalfOf() public {
        _registerMarketContracts();
        _setupWethReserve();
        _setupUsdcReserve();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken usdcSupplyToken = ScaledSupplyToken(usdcReserve.supplyToken);
        ScaledDebtToken usdcDebtToken = ScaledDebtToken(usdcReserve.debtToken);

        // Alice supplies collateral.
        weth.mint(alice, 1 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        pool.supply(address(weth), 1 ether, alice);
        pool.setUserUseReserveAsCollateral(address(weth), true);
        vm.stopPrank();

        // Bob funds the USDC reserve.
        usdc.mint(bob, 2000e6);

        vm.startPrank(bob);
        usdc.approve(address(pool), 2000e6);
        pool.supply(address(usdc), 2000e6, bob);
        vm.stopPrank();

        // Indexes are WAD: actual and scaled debt match.
        assertEq(pool.currentBorrowIndex(address(usdc)), DecimalMath.WAD);
        assertEq(pool.availableLiquidity(address(usdc)), 2000e6);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdcDebtToken.balanceOf(alice), 0);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Borrowed(address(usdc), alice, alice, 1000e6, 1000e6);

        vm.prank(alice);
        pool.borrow(address(usdc), 1000e6, alice);

        // Underlying movement.
        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(usdc.balanceOf(address(usdcSupplyToken)), 1000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);

        // Debt belongs to Alice.
        assertEq(usdcDebtToken.scaledBalanceOf(alice), 1000e6);
        assertEq(usdcDebtToken.balanceOf(alice), 1000e6);
        assertEq(usdcDebtToken.balanceOf(bob), 0);
        assertEq(pool.totalScaledDebt(address(usdc)), 1000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);

        // Bob's supplier claim remains intact.
        assertEq(usdcSupplyToken.scaledBalanceOf(bob), 2000e6);
        assertEq(usdcSupplyToken.balanceOf(bob), 2000e6);
        assertEq(pool.totalSupply(address(usdc)), 2000e6);

        // Collateral remains in the WETH reserve.
        assertEq(weth.balanceOf(wethReserve.supplyToken), 1 ether);
        assertEq(ScaledSupplyToken(wethReserve.supplyToken).balanceOf(alice), 1 ether);
        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        // Risk data includes the newly created debt.
        DataTypes.AccountData memory data = pool.getUserAccountData(alice);

        assertEq(data.collateralValueWad, 2000e18);
        assertEq(data.debtValueWad, 1000e18);
        assertEq(data.borrowCapacityWad, 1500e18);
        assertEq(data.liquidationCapacityWad, 1600e18);
        assertEq(data.availableBorrowsWad, 500e18);
        assertEq(data.healthFactorWad, 1.6e18);

        // New rates apply to the interval after borrowing.
        usdcReserve = pool.getReserveData(address(usdc));

        assertEq(pool.utilization(address(usdc)), 0.5e18);
        assertEq(usdcReserve.state.currentBorrowRate, 0.045e18);
        assertEq(usdcReserve.state.currentLiquidityRate, 0.02025e18);

        // No elapsed time means no accrued interest yet.
        assertEq(usdcReserve.state.accruedToTreasury, 0);
        assertEq(usdcReserve.state.lastUpdateTimestamp, block.timestamp);

        assertEq(pool.totalDebt(address(usdc)), 1000e6);

        // Charlie pays from his own wallet; Alice owns the debt.
        usdc.mint(charlie, 400e6);

        vm.startPrank(charlie);
        usdc.approve(address(pool), 400e6);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Repaid(address(usdc), charlie, alice, 400e6, 400e6);

        uint256 repaid = pool.repay(address(usdc), 400e6, alice);

        vm.stopPrank();

        assertEq(repaid, 400e6);
        assertEq(usdc.balanceOf(charlie), 0);

        // Alice keeps the borrowed funds; Charlie funded repayment.
        assertEq(usdc.balanceOf(alice), 1000e6);

        assertEq(usdcDebtToken.balanceOf(alice), 600e6);
        assertEq(usdcDebtToken.balanceOf(charlie), 0);
        assertEq(usdcDebtToken.borrowAllowance(alice, charlie), 0);

        assertEq(pool.availableLiquidity(address(usdc)), 1400e6);
        assertEq(usdc.balanceOf(address(usdcSupplyToken)), 1400e6);

        assertEq(pool.totalDebt(address(usdc)), 600e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 600e6);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Repaid(address(usdc), alice, alice, 600e6, 600e6);

        repaid = pool.repay(address(usdc), 600e6, alice);

        vm.stopPrank();

        assertEq(repaid, 600e6);

        assertEq(usdc.balanceOf(alice), 400e6);
        assertEq(usdcDebtToken.balanceOf(alice), 0);
        assertEq(pool.totalDebt(address(usdc)), 0);
    }

    function test_repay_reverts() public {
        vm.prank(alice);
        vm.expectRevert(Pool.ZeroAddress.selector);
        pool.repay(address(0), 1000e6, alice);

        vm.prank(alice);
        vm.expectRevert(Pool.ZeroAddress.selector);
        pool.repay(alice, 1000e6, address(0));

        vm.prank(alice);
        vm.expectRevert(Pool.ZeroAmount.selector);
        pool.repay(alice, 0, alice);
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

    function test_repay_partialAtRaisedIndex_roundsScaledBurnDown() public {
        _setupUsdcLoan();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        ScaledDebtToken debtToken = ScaledDebtToken(reserve.debtToken);

        skip(365 days);

        assertEq(pool.currentBorrowIndex(address(usdc)), 1.045e18);
        assertEq(debtToken.balanceOf(alice), 1045e6);

        // Oracle feeds are stale; repayment must still work.
        vm.startPrank(alice);
        usdc.approve(address(pool), 400e6);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Repaid(address(usdc), alice, alice, 400e6, 382_775_119);

        uint256 repaid = pool.repay(address(usdc), 400e6, alice);
        vm.stopPrank();

        assertEq(repaid, 400e6);
        assertEq(usdc.balanceOf(alice), 600e6);

        // floor(400_000_000 / 1.045) = 382_775_119 scaled units

        // remaining scaled debt = 617_224_881
        // actual debt = ceil(617_224_881 × 1.045) = 645_000_001

        assertEq(debtToken.scaledBalanceOf(alice), 617_224_881);
        assertEq(debtToken.balanceOf(alice), 645_000_001);
        assertEq(pool.totalScaledDebt(address(usdc)), 617_224_881);
        assertEq(pool.totalDebt(address(usdc)), 645_000_001);

        assertEq(pool.availableLiquidity(address(usdc)), 1400e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 1400e6);

        reserve = pool.getReserveData(address(usdc));

        assertEq(reserve.state.borrowIndex, 1.045e18);
        assertEq(reserve.state.liquidityIndex, 1.02025e18);
        assertEq(reserve.state.accruedToTreasury, 4.5e6);
        assertEq(reserve.state.lastUpdateTimestamp, block.timestamp);
    }

    function test_repay_revertsWhenScaledBurnIsZero() public {
        _setupUsdcLoan();

        DataTypes.ReserveData memory beforeRepay = pool.getReserveData(address(usdc));

        ScaledDebtToken debtToken = ScaledDebtToken(beforeRepay.debtToken);

        skip(365 days);

        assertEq(pool.currentBorrowIndex(address(usdc)), 1.045e18);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1);

        vm.expectRevert(abi.encodeWithSelector(Pool.RepayTooSmall.selector, 1));
        pool.repay(address(usdc), 1, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(usdc.allowance(alice, address(pool)), 1);

        assertEq(debtToken.scaledBalanceOf(alice), 1000e6);
        assertEq(debtToken.balanceOf(alice), 1045e6);
        assertEq(pool.totalScaledDebt(address(usdc)), 1000e6);

        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(usdc.balanceOf(beforeRepay.supplyToken), 1000e6);

        // Accrual inside the reverted repayment is rolled back too.
        DataTypes.ReserveData memory afterRepay = pool.getReserveData(address(usdc));

        assertEq(afterRepay.state.borrowIndex, beforeRepay.state.borrowIndex);
        assertEq(afterRepay.state.liquidityIndex, beforeRepay.state.liquidityIndex);
        assertEq(afterRepay.state.accruedToTreasury, beforeRepay.state.accruedToTreasury);
        assertEq(afterRepay.state.lastUpdateTimestamp, beforeRepay.state.lastUpdateTimestamp);
    }
}
