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

contract PoolReserveStatusTest is Test {
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

    event ReserveCapsUpdated(address indexed asset, uint256 supplyCap, uint256 borrowCap);

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

    function test_setReserveFreeze() public {
        _setupUsdcLoan();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        assertEq(pool.totalSupply(address(weth)), 1 ether);
        assertEq(pool.totalSupply(address(usdc)), 2000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);

        assertFalse(reserve.configuration.frozen);

        vm.prank(admin);
        configurator.setReserveFreeze(address(usdc), true);

        reserve = pool.getReserveData(address(usdc));

        assertTrue(reserve.configuration.frozen);

        // WETH is not frozen
        weth.mint(alice, 1 ether);
        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        pool.supply(address(weth), 1 ether, alice);
        vm.stopPrank();

        assertEq(pool.totalSupply(address(weth)), 2 ether);
        assertEq(pool.totalSupply(address(usdc)), 2000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);

        // USDC is frozen for supply & borrow ops
        usdc.mint(bob, 2000e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 2000e6);

        vm.expectRevert(abi.encodeWithSelector(Pool.ReserveFrozen.selector, address(usdc)));
        pool.supply(address(usdc), 2000e6, bob);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Pool.ReserveFrozen.selector, address(usdc)));
        pool.borrow(address(usdc), 1000e6, alice);

        assertEq(pool.totalSupply(address(weth)), 2 ether);
        assertEq(pool.totalSupply(address(usdc)), 2000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);

        // repay & withdraw  are available
        vm.startPrank(alice);
        usdc.approve(address(pool), 100e6);
        pool.repay(address(usdc), 100e6, alice);
        vm.stopPrank();

        assertEq(pool.totalSupply(address(weth)), 2 ether);
        assertEq(pool.totalSupply(address(usdc)), 2000e6);
        assertEq(pool.totalDebt(address(usdc)), 900e6);

        vm.prank(bob);
        pool.withdraw(address(usdc), 200e6, bob);

        assertEq(pool.totalSupply(address(weth)), 2 ether);
        assertEq(pool.totalSupply(address(usdc)), 1800e6);
        assertEq(pool.totalDebt(address(usdc)), 900e6);
    }

    function test_setReservePause() public {
        _setupUsdcLoan();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        assertEq(pool.totalSupply(address(weth)), 1 ether);
        assertEq(pool.totalSupply(address(usdc)), 2000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);

        assertFalse(reserve.configuration.paused);

        vm.prank(admin);
        configurator.setReservePause(address(usdc), true);

        reserve = pool.getReserveData(address(usdc));

        assertTrue(reserve.configuration.paused);

        // WETH is not paused
        weth.mint(alice, 1 ether);
        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        pool.supply(address(weth), 1 ether, alice);
        vm.stopPrank();

        assertEq(pool.totalSupply(address(weth)), 2 ether);
        assertEq(pool.totalSupply(address(usdc)), 2000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);

        // USDC is paused for supply / borrow / repay / withdraw ops
        usdc.mint(bob, 2000e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), 2000e6);

        vm.expectRevert(abi.encodeWithSelector(Pool.ReservePaused.selector, address(usdc)));
        pool.supply(address(usdc), 2000e6, bob);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Pool.ReservePaused.selector, address(usdc)));
        pool.borrow(address(usdc), 1000e6, alice);

        assertEq(pool.totalSupply(address(weth)), 2 ether);
        assertEq(pool.totalSupply(address(usdc)), 2000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 100e6);

        vm.expectRevert(abi.encodeWithSelector(Pool.ReservePaused.selector, address(usdc)));
        pool.repay(address(usdc), 100e6, alice);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Pool.ReservePaused.selector, address(usdc)));
        pool.withdraw(address(usdc), 200e6, bob);

        assertEq(pool.totalSupply(address(weth)), 2 ether);
        assertEq(pool.totalSupply(address(usdc)), 2000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);
    }

    function test_setReserveFreeze_reverts() public {
        _setupUsdcLoan();

        assertFalse(pool.getReserveData(address(usdc)).configuration.frozen);

        vm.expectRevert(); //OwnableUnauthorizedAccount
        configurator.setReserveFreeze(address(usdc), true);

        vm.prank(admin);
        vm.expectRevert(PoolConfigurator.ZeroAddress.selector);
        configurator.setReserveFreeze(address(0), true);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Pool.OnlyConfigurator.selector, admin));
        pool.setReserveFreeze(address(usdc), true);

        assertFalse(pool.getReserveData(address(usdc)).configuration.frozen);
    }

    function test_setReservePause_reverts() public {
        _setupUsdcLoan();

        assertFalse(pool.getReserveData(address(usdc)).configuration.paused);

        vm.expectRevert(); //OwnableUnauthorizedAccount
        configurator.setReservePause(address(usdc), true);

        vm.prank(admin);
        vm.expectRevert(PoolConfigurator.ZeroAddress.selector);
        configurator.setReservePause(address(0), true);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Pool.OnlyConfigurator.selector, admin));
        pool.setReservePause(address(usdc), true);

        assertFalse(pool.getReserveData(address(usdc)).configuration.paused);
    }

    function test_pause_blocksSupplyTokenTransfers() public {
        _setupUsdcLoan();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken supplyToken = ScaledSupplyToken(reserve.supplyToken);

        vm.prank(bob);
        supplyToken.approve(charlie, 100e6);

        vm.prank(admin);
        configurator.setReservePause(address(usdc), true);

        bytes memory expectedError = abi.encodeWithSelector(Pool.ReservePaused.selector, address(usdc));

        vm.expectRevert(expectedError);
        vm.prank(bob);
        supplyToken.transfer(charlie, 100e6);

        vm.expectRevert(expectedError);
        vm.prank(charlie);
        supplyToken.transferFrom(bob, charlie, 100e6);

        // Allowance spending must roll back with the failed transfer.
        assertEq(supplyToken.allowance(bob, charlie), 100e6);

        vm.expectRevert(expectedError);
        vm.prank(bob);
        supplyToken.transfer(bob, 100e6);

        vm.expectRevert(expectedError);
        vm.prank(bob);
        supplyToken.transfer(charlie, 0);

        assertEq(supplyToken.scaledBalanceOf(bob), 2000e6);
        assertEq(supplyToken.scaledBalanceOf(charlie), 0);
        assertEq(supplyToken.scaledTotalSupply(), 2000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);

        // The same transfer succeeds after unpause.
        vm.prank(admin);
        configurator.setReservePause(address(usdc), false);

        vm.prank(charlie);
        supplyToken.transferFrom(bob, charlie, 100e6);

        assertEq(supplyToken.balanceOf(bob), 1900e6);
        assertEq(supplyToken.balanceOf(charlie), 100e6);
        assertEq(supplyToken.allowance(bob, charlie), 0);
    }

    function test_pause_blocksCollateralToggle() public {
        _registerMarketContracts();
        _setupWethReserve();

        weth.mint(alice, 1 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);
        pool.supply(address(weth), 1 ether, alice);
        vm.stopPrank();

        vm.prank(admin);
        configurator.setReservePause(address(weth), true);

        vm.expectRevert(abi.encodeWithSelector(Pool.ReservePaused.selector, address(weth)));
        vm.prank(alice);
        pool.setUserUseReserveAsCollateral(address(weth), true);

        assertFalse(pool.isUsingAsCollateral(alice, address(weth)));

        vm.prank(admin);
        configurator.setReservePause(address(weth), false);

        vm.prank(alice);
        pool.setUserUseReserveAsCollateral(address(weth), true);

        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        vm.prank(admin);
        configurator.setReservePause(address(weth), true);

        vm.expectRevert(abi.encodeWithSelector(Pool.ReservePaused.selector, address(weth)));
        vm.prank(alice);
        pool.setUserUseReserveAsCollateral(address(weth), false);

        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        vm.prank(admin);
        configurator.setReservePause(address(weth), false);

        vm.prank(alice);
        pool.setUserUseReserveAsCollateral(address(weth), false);

        assertFalse(pool.isUsingAsCollateral(alice, address(weth)));
    }

    function test_pause_blocksTreasuryMint() public {
        _setupUsdcLoan();

        address treasury = address(0x2000);

        vm.startPrank(admin);
        provider.setTreasury(treasury);
        configurator.setReservePause(address(usdc), true);
        vm.stopPrank();

        DataTypes.ReserveData memory beforeReserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken supplyToken = ScaledSupplyToken(beforeReserve.supplyToken);

        skip(365 days);

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);

        vm.expectRevert(abi.encodeWithSelector(Pool.ReservePaused.selector, address(usdc)));
        pool.mintToTreasury(assets);

        DataTypes.ReserveData memory afterReserve = pool.getReserveData(address(usdc));

        assertEq(supplyToken.scaledBalanceOf(treasury), 0);
        assertEq(afterReserve.state.lastUpdateTimestamp, beforeReserve.state.lastUpdateTimestamp);
        assertEq(afterReserve.state.accruedToTreasuryScaled, beforeReserve.state.accruedToTreasuryScaled);

        vm.prank(admin);
        configurator.setReservePause(address(usdc), false);

        pool.mintToTreasury(assets);

        assertEq(supplyToken.scaledBalanceOf(treasury), 4_410_683);
        assertEq(pool.getReserveData(address(usdc)).state.accruedToTreasuryScaled, 0);
    }

    function test_pause_blocksLiquidationUntilBothReservesUnpaused() public {
        _setupUsdcLoan();

        wethFeed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 2, answer: 1000e8, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 2
            })
        );

        assertEq(pool.getUserAccountData(alice).healthFactorWad, 0.8e18);

        usdc.mint(charlie, 500e6);

        vm.prank(charlie);
        usdc.approve(address(pool), 500e6);

        vm.prank(admin);
        configurator.setReservePause(address(weth), true);

        vm.expectRevert(abi.encodeWithSelector(Pool.ReservePaused.selector, address(weth)));
        vm.prank(charlie);
        pool.liquidationCall(address(weth), address(usdc), alice, 500e6, false);

        vm.startPrank(admin);
        configurator.setReservePause(address(weth), false);
        configurator.setReservePause(address(usdc), true);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Pool.ReservePaused.selector, address(usdc)));
        vm.prank(charlie);
        pool.liquidationCall(address(weth), address(usdc), alice, 500e6, false);

        // Both rejected attempts preserve payment and positions.
        assertEq(usdc.balanceOf(charlie), 500e6);
        assertEq(usdc.allowance(charlie, address(pool)), 500e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);
        assertEq(pool.totalSupply(address(weth)), 1 ether);

        vm.prank(admin);
        configurator.setReservePause(address(usdc), false);

        vm.prank(charlie);
        (uint256 debtRepaid, uint256 collateralSeized) =
            pool.liquidationCall(address(weth), address(usdc), alice, 500e6, false);

        assertEq(debtRepaid, 500e6);
        assertEq(collateralSeized, 0.525 ether);
        assertEq(pool.totalDebt(address(usdc)), 500e6);
        assertEq(usdc.balanceOf(charlie), 0);
        assertEq(weth.balanceOf(charlie), 0.525 ether);
    }

    function test_unpause_preservesFreeze() public {
        _setupUsdcLoan();

        vm.startPrank(admin);
        configurator.setReserveFreeze(address(usdc), true);
        configurator.setReservePause(address(usdc), true);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Pool.ReservePaused.selector, address(usdc)));
        vm.prank(alice);
        pool.borrow(address(usdc), 100e6, alice);

        vm.prank(admin);
        configurator.setReservePause(address(usdc), false);

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        assertFalse(reserve.configuration.paused);
        assertTrue(reserve.configuration.frozen);

        vm.expectRevert(abi.encodeWithSelector(Pool.ReserveFrozen.selector, address(usdc)));
        vm.prank(alice);
        pool.borrow(address(usdc), 100e6, alice);

        vm.prank(admin);
        configurator.setReserveFreeze(address(usdc), false);

        vm.prank(alice);
        pool.borrow(address(usdc), 100e6, alice);

        assertEq(pool.totalDebt(address(usdc)), 1100e6);
        assertEq(pool.availableLiquidity(address(usdc)), 900e6);
        assertEq(usdc.balanceOf(alice), 1100e6);
    }
}
