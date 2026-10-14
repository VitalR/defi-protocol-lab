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

contract PoolBorrowTest is Test {
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
}
