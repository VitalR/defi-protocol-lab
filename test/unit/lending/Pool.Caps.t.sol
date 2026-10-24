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

contract PoolCapsTest is Test {
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

    function test_setReserveCaps_zeroCaps() public {
        _setupUsdcLoan();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveConfiguration memory wethConfig = wethReserve.configuration;

        assertEq(wethConfig.supplyCap, 0);
        assertEq(wethConfig.borrowCap, 0);

        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));
        DataTypes.ReserveConfiguration memory usdcConfig = usdcReserve.configuration;

        assertEq(usdcConfig.supplyCap, 0);
        assertEq(usdcConfig.borrowCap, 0);

        assertEq(pool.availableLiquidity(address(weth)), 1 ether);
        assertEq(pool.totalScaledSupply(address(weth)), 1 ether);
        assertEq(pool.totalSupply(address(weth)), 1 ether);

        assertEq(pool.totalScaledDebt(address(weth)), 0e6);
        assertEq(pool.totalDebt(address(weth)), 0e6);

        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 2000e6);
        assertEq(pool.totalSupply(address(usdc)), 2000e6);

        assertEq(pool.totalScaledDebt(address(usdc)), 1000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);
    }

    function test_supply_withSupplyCap() public {
        _registerMarketContracts();
        _setupWethReserve();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));
        DataTypes.ReserveConfiguration memory config = reserve.configuration;

        assertEq(config.supplyCap, 0);
        assertEq(config.borrowCap, 0);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ReserveCapsUpdated(address(weth), 10 ether, 0);
        configurator.setReserveCaps(address(weth), 10 ether, 0);

        reserve = pool.getReserveData(address(weth));
        config = reserve.configuration;

        assertEq(config.supplyCap, 10 ether);
        assertEq(config.borrowCap, 0);

        weth.mint(alice, 10 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 10 ether);
        pool.supply(address(weth), 10 ether, alice);
        vm.stopPrank();

        assertEq(pool.availableLiquidity(address(weth)), 10 ether);
        assertEq(pool.totalScaledSupply(address(weth)), 10 ether);
        assertEq(pool.totalSupply(address(weth)), 10 ether);

        weth.mint(alice, 1 wei);

        vm.startPrank(alice);
        weth.approve(address(pool), 1 wei);

        vm.expectRevert(
            abi.encodeWithSelector(Pool.SupplyCapExceeded.selector, address(weth), 10 ether, 10 ether, 1 wei)
        );
        pool.supply(address(weth), 1 wei, alice);
        vm.stopPrank();

        assertEq(pool.availableLiquidity(address(weth)), 10 ether);
        assertEq(pool.totalScaledSupply(address(weth)), 10 ether);
        assertEq(pool.totalSupply(address(weth)), 10 ether);
    }

    function test_borrow_withBorrowCap() public {
        _registerMarketContracts();
        _setupWethReserve();
        _setupUsdcReserve();

        DataTypes.ReserveData memory wethReserve = pool.getReserveData(address(weth));
        DataTypes.ReserveConfiguration memory wethConfig = wethReserve.configuration;

        assertEq(wethConfig.supplyCap, 0);
        assertEq(wethConfig.borrowCap, 0);

        DataTypes.ReserveData memory usdcReserve = pool.getReserveData(address(usdc));
        DataTypes.ReserveConfiguration memory usdcConfig = usdcReserve.configuration;

        assertEq(usdcConfig.supplyCap, 0);
        assertEq(usdcConfig.borrowCap, 0);

        vm.startPrank(admin);

        vm.expectEmit(true, false, false, true, address(pool));
        emit ReserveCapsUpdated(address(weth), 10 ether, 5 ether);
        configurator.setReserveCaps(address(weth), 10 ether, 5 ether);

        vm.expectEmit(true, false, false, true, address(pool));
        emit ReserveCapsUpdated(address(usdc), 1_000_000e6, 1000e6);
        configurator.setReserveCaps(address(usdc), 1_000_000e6, 1000e6);

        vm.stopPrank();

        weth.mint(alice, 10 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 10 ether);
        pool.supply(address(weth), 10 ether, alice);
        pool.setUserUseReserveAsCollateral(address(weth), true);
        vm.stopPrank();

        assertEq(pool.availableLiquidity(address(weth)), 10 ether);
        assertEq(pool.totalScaledSupply(address(weth)), 10 ether);
        assertEq(pool.totalSupply(address(weth)), 10 ether);

        usdcReserve = pool.getReserveData(address(usdc));
        usdcConfig = usdcReserve.configuration;

        assertEq(usdcConfig.supplyCap, 1_000_000e6);
        assertEq(usdcConfig.borrowCap, 1000e6);

        usdc.mint(bob, 1_000_000e6);

        vm.startPrank(bob);
        usdc.approve(address(pool), 1_000_000e6);
        pool.supply(address(usdc), 1_000_000e6, bob);
        vm.stopPrank();

        assertEq(pool.availableLiquidity(address(usdc)), 1_000_000e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 1_000_000e6);
        assertEq(pool.totalSupply(address(usdc)), 1_000_000e6);

        assertEq(pool.totalScaledDebt(address(usdc)), 0e6);
        assertEq(pool.totalDebt(address(usdc)), 0e6);

        vm.prank(alice);
        pool.borrow(address(usdc), 1000e6, alice);

        // Borrowing exactly up to the cap succeeds.
        assertEq(pool.totalScaledDebt(address(usdc)), 1000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);

        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 999_000e6);

        // Borrowing does not burn the supplier's claim.
        assertEq(pool.totalScaledSupply(address(usdc)), 1_000_000e6);
        assertEq(pool.totalSupply(address(usdc)), 1_000_000e6);

        // Another microUSDC would exceed the reserve cap.
        vm.expectRevert(abi.encodeWithSelector(Pool.BorrowCapExceeded.selector, address(usdc), 1000e6, 1000e6 + 1));
        vm.prank(alice);
        pool.borrow(address(usdc), 1, alice);

        // Failed borrowing leaves debt and cash unchanged.
        assertEq(pool.totalDebt(address(usdc)), 1000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 999_000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);
    }

    function test_setReserveCaps_reverts() public {
        _registerMarketContracts();
        _setupWethReserve();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));
        DataTypes.ReserveConfiguration memory config = reserve.configuration;

        assertEq(config.supplyCap, 0);
        assertEq(config.borrowCap, 0);

        vm.expectRevert(); //OwnableUnauthorizedAccount
        configurator.setReserveCaps(address(weth), 10 ether, 0);

        vm.prank(admin);
        vm.expectRevert(PoolConfigurator.ZeroAddress.selector);
        configurator.setReserveCaps(address(0), 10 ether, 0);

        reserve = pool.getReserveData(address(weth));
        config = reserve.configuration;

        assertEq(config.supplyCap, 0);
        assertEq(config.borrowCap, 0);

        vm.expectRevert(abi.encodeWithSelector(Pool.OnlyConfigurator.selector, admin));
        vm.prank(admin);
        pool.setReserveCaps(address(weth), 10 ether, 0);
    }

    function test_supply_capIncludesPendingTreasury() public {
        _setupUsdcLoan();

        skip(365 days);

        // Repayment commits interest and creates pending treasury shares.
        vm.startPrank(alice);
        usdc.approve(address(pool), 100e6);
        pool.repay(address(usdc), 100e6, alice);
        vm.stopPrank();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken supplyToken = ScaledSupplyToken(reserve.supplyToken);

        assertEq(supplyToken.totalSupply(), 2040.5e6);
        assertEq(reserve.state.accruedToTreasuryScaled, 4_410_683);

        uint256 cap = 2042e6;
        uint256 amount = 1e6;

        // Minted claims alone would allow this deposit.
        assertLt(supplyToken.totalSupply() + amount, cap);

        uint256 effectiveSupply = Math.mulDiv(
            supplyToken.scaledTotalSupply() + reserve.state.accruedToTreasuryScaled,
            reserve.state.liquidityIndex,
            DecimalMath.WAD,
            Math.Rounding.Ceil
        );

        assertGt(effectiveSupply, cap);

        vm.prank(admin);
        configurator.setReserveCaps(address(usdc), cap, 0);

        usdc.mint(charlie, amount);

        vm.prank(charlie);
        usdc.approve(address(pool), amount);

        uint256 cashBefore = pool.availableLiquidity(address(usdc));
        uint256 scaledSupplyBefore = supplyToken.scaledTotalSupply();

        vm.expectRevert(
            abi.encodeWithSelector(Pool.SupplyCapExceeded.selector, address(usdc), cap, effectiveSupply, amount)
        );
        vm.prank(charlie);
        pool.supply(address(usdc), amount, charlie);

        assertEq(usdc.balanceOf(charlie), amount);
        assertEq(supplyToken.scaledBalanceOf(charlie), 0);
        assertEq(supplyToken.scaledTotalSupply(), scaledSupplyBefore);
        assertEq(pool.availableLiquidity(address(usdc)), cashBefore);

        assertEq(
            pool.getReserveData(address(usdc)).state.accruedToTreasuryScaled, reserve.state.accruedToTreasuryScaled
        );
    }

    function test_loweredCaps_blockNewSupplyAndBorrow_allowRepayAndWithdraw() public {
        _setupUsdcLoan();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        ScaledSupplyToken supplyToken = ScaledSupplyToken(reserve.supplyToken);

        ScaledDebtToken debtToken = ScaledDebtToken(reserve.debtToken);

        vm.prank(admin);
        configurator.setReserveCaps(address(usdc), 1500e6, 500e6);

        // Changing caps does not change existing positions.
        assertEq(pool.totalSupply(address(usdc)), 2000e6);
        assertEq(pool.totalDebt(address(usdc)), 1000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);

        usdc.mint(charlie, 1e6);

        vm.prank(charlie);
        usdc.approve(address(pool), 1e6);

        vm.expectRevert(abi.encodeWithSelector(Pool.SupplyCapExceeded.selector, address(usdc), 1500e6, 2000e6, 1e6));
        vm.prank(charlie);
        pool.supply(address(usdc), 1e6, charlie);

        vm.expectRevert(abi.encodeWithSelector(Pool.BorrowCapExceeded.selector, address(usdc), 500e6, 1000e6 + 1));
        vm.prank(alice);
        pool.borrow(address(usdc), 1, alice);

        // Existing debt can be reduced while still above the cap.
        vm.startPrank(alice);
        usdc.approve(address(pool), 100e6);
        uint256 repaid = pool.repay(address(usdc), 100e6, alice);
        vm.stopPrank();

        assertEq(repaid, 100e6);
        assertEq(debtToken.balanceOf(alice), 900e6);
        assertEq(usdc.balanceOf(alice), 900e6);

        // Existing supply can be withdrawn while still above the cap.
        vm.prank(bob);
        uint256 withdrawn = pool.withdraw(address(usdc), 200e6, bob);

        assertEq(withdrawn, 200e6);
        assertEq(usdc.balanceOf(bob), 200e6);
        assertEq(supplyToken.balanceOf(bob), 1800e6);

        assertEq(pool.totalSupply(address(usdc)), 1800e6);
        assertEq(pool.totalDebt(address(usdc)), 900e6);
        assertEq(pool.availableLiquidity(address(usdc)), 900e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 900e6);

        reserve = pool.getReserveData(address(usdc));

        assertEq(reserve.configuration.supplyCap, 1500e6);
        assertEq(reserve.configuration.borrowCap, 500e6);

        assertGt(pool.totalSupply(address(usdc)), 1500e6);
        assertGt(pool.totalDebt(address(usdc)), 500e6);
    }
}
