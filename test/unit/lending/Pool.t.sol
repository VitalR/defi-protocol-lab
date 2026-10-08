// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { Pool, DataTypes } from "src/lending/Pool.sol";
import { PoolAddressProvider } from "src/lending/PoolAddressProvider.sol";
import { PoolConfigurator } from "src/lending/PoolConfigurator.sol";
import { ScaledSupplyToken } from "src/lending/tokens/ScaledSupplyToken.sol";
import { ScaledDebtToken } from "src/lending/tokens/ScaledDebtToken.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";
import { MockWETH } from "test/mocks/MockWETH.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";
import { MockERC20Decimals } from "test/mocks/MockERC20Decimals.sol";
import { MockFeeOnTransferERC20 } from "test/mocks/MockFeeOnTransferERC20.sol";
import { PoolHarness } from "test/helpers/PoolHarness.sol";

contract PoolTest is Test {
    Pool pool;
    PoolAddressProvider provider;
    PoolConfigurator configurator;
    MockWETH weth;
    MockUSDC usdc;

    address admin = address(0x1000);
    address alice = address(0x1001);
    address bob = address(0x1002);
    address borrower = address(0x1003);

    event ReserveInitialized(
        address indexed asset, address indexed supplyToken, address indexed debtToken, uint8 decimals
    );
    event ReserveConfigured(
        address indexed asset, uint256 ltvWad, uint256 liquidationThresholdWad, bool borrowingEnabled
    );
    event Supplied(
        address indexed asset,
        address indexed caller,
        address indexed onBehalfOf,
        uint256 actualAmount,
        uint256 scaledAmount
    );
    event Withdrawn(
        address indexed asset, address indexed user, address indexed to, uint256 actualAmount, uint256 scaledAmount
    );
    event UserCollateralUsageChanged(address indexed user, address indexed asset, bool enabled);

    function setUp() public {
        provider = new PoolAddressProvider(admin);
        configurator = new PoolConfigurator(admin, address(provider));
        pool = new PoolHarness(address(provider));
        weth = new MockWETH();
        usdc = new MockUSDC();
    }

    function test_constructor_configuration() public {
        assertEq(provider.owner(), admin);
        assertEq(configurator.owner(), admin);
        assertEq(address(configurator.ADDRESSES_PROVIDER()), address(provider));
        assertEq(address(pool.ADDRESSES_PROVIDER()), address(provider));
    }

    function test_constructor_configuration_reverts() public {
        vm.expectRevert(Pool.ZeroAddress.selector);
        new Pool(address(0));

        vm.expectRevert(abi.encodeWithSelector(Pool.InvalidAddressProvider.selector, alice));
        new Pool(alice);
    }

    function _setPoolAddresses() internal {
        vm.startPrank(admin);
        provider.setPool(address(pool));
        provider.setPoolConfigurator(address(configurator));
        vm.stopPrank();
    }

    function test_initReserve_weth() public {
        _setPoolAddresses();

        vm.prank(admin);
        configurator.initReserve(address(weth));

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));

        assertTrue(reserve.initialized);
        assertEq(reserve.decimals, DecimalMath.WAD_DECIMALS);

        assertEq(reserve.state.borrowIndex, DecimalMath.WAD);
        assertEq(reserve.state.liquidityIndex, DecimalMath.WAD);
        assertEq(reserve.state.currentBorrowRate, pool.BASE_RATE());
        assertEq(reserve.state.currentLiquidityRate, 0);
        assertEq(reserve.state.reserveFactor, pool.DEFAULT_RESERVE_FACTOR());
        assertEq(reserve.state.lastUpdateTimestamp, block.timestamp);

        assertEq(IERC20Metadata(reserve.supplyToken).symbol(), "aWETH");
        assertEq(IERC20Metadata(reserve.debtToken).symbol(), "vdWETH");

        assertEq(pool.getReservesList().length, 1);

        assertEq(pool.currentBorrowIndex(address(weth)), DecimalMath.WAD);
        assertEq(pool.currentLiquidityIndex(address(weth)), DecimalMath.WAD);
    }

    function _setInitReserveWeth() internal {
        vm.prank(admin);
        configurator.initReserve(address(weth));

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));
        assertTrue(reserve.initialized);
    }

    function test_initReserve_weth_usdc() public {
        _setPoolAddresses();
        _setInitReserveWeth();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));
        assertTrue(reserve.initialized);
        assertEq(pool.getReservesList().length, 1);

        vm.prank(admin);
        configurator.initReserve(address(usdc));

        reserve = pool.getReserveData(address(usdc));

        assertTrue(reserve.initialized);
        assertEq(reserve.decimals, 6);

        assertEq(reserve.state.borrowIndex, DecimalMath.WAD);
        assertEq(reserve.state.liquidityIndex, DecimalMath.WAD);
        assertEq(reserve.state.currentBorrowRate, pool.BASE_RATE());
        assertEq(reserve.state.currentLiquidityRate, 0);
        assertEq(reserve.state.reserveFactor, pool.DEFAULT_RESERVE_FACTOR());
        assertEq(reserve.state.lastUpdateTimestamp, block.timestamp);

        assertEq(IERC20Metadata(reserve.supplyToken).symbol(), "aUSDC");
        assertEq(IERC20Metadata(reserve.debtToken).symbol(), "vdUSDC");

        assertEq(pool.getReservesList().length, 2);

        assertEq(pool.currentBorrowIndex(address(usdc)), DecimalMath.WAD);
        assertEq(pool.currentLiquidityIndex(address(usdc)), DecimalMath.WAD);
    }

    function test_initReserve_reverts() public {
        _setPoolAddresses();

        vm.expectRevert(); //OwnableUnauthorizedAccount
        configurator.initReserve(address(weth));

        vm.prank(admin);
        vm.expectRevert(PoolConfigurator.ZeroAddress.selector);
        configurator.initReserve(address(0));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Pool.OnlyConfigurator.selector, admin));
        pool.initReserve(address(usdc));

        MockERC20Decimals mockAsset19Decimals = new MockERC20Decimals("MockERC20Decimals", "M19D", 19);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Pool.UnsupportedAssetDecimals.selector, 19));
        configurator.initReserve(address(mockAsset19Decimals));

        vm.startPrank(admin);
        configurator.initReserve(address(weth));
        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));
        assertTrue(reserve.initialized);

        vm.expectRevert(abi.encodeWithSelector(Pool.ReserveAlreadyInitialized.selector, address(weth)));
        configurator.initReserve(address(weth));
        vm.stopPrank();
    }

    function test_getReserveData_revertsWhenUnsupportedAsset() public {
        _setPoolAddresses();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Pool.UnsupportedAsset.selector, address(usdc)));
        pool.getReserveData(address(usdc));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Pool.UnsupportedAsset.selector, address(usdc)));
        pool.currentBorrowIndex(address(usdc));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Pool.UnsupportedAsset.selector, address(usdc)));
        pool.currentLiquidityIndex(address(usdc));
    }

    ///// Supply Logic /////

    function _setInitReserve(address asset) internal {
        vm.prank(admin);
        configurator.initReserve(address(asset));

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(asset));
        assertTrue(reserve.initialized);
    }

    function _supplyAliceUsdc(uint256 amount) internal {
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(pool), amount);
        pool.supply(address(usdc), amount, alice);
        vm.stopPrank();
    }

    function test_supply_usdc() public {
        _setPoolAddresses();
        _setInitReserve(address(usdc));

        usdc.mint(alice, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Supplied(address(usdc), alice, alice, 1000e6, 1000e6);
        pool.supply(address(usdc), 1000e6, alice);
        vm.stopPrank();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 1000e6);

        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 1000e6);

        assertEq(pool.totalScaledDebt(address(usdc)), 0e6);
        assertEq(pool.totalDebt(address(usdc)), 0e6);

        ScaledSupplyToken supplyToken = ScaledSupplyToken(reserve.supplyToken);

        assertEq(supplyToken.scaledBalanceOf(alice), 1000e6);
        assertEq(supplyToken.balanceOf(alice), 1000e6);

        assertEq(pool.currentBorrowIndex(address(usdc)), reserve.state.borrowIndex);
        assertEq(pool.currentBorrowIndex(address(usdc)), DecimalMath.WAD);
        assertEq(pool.currentLiquidityIndex(address(usdc)), reserve.state.liquidityIndex);
        assertEq(pool.currentLiquidityIndex(address(usdc)), DecimalMath.WAD);

        assertEq(pool.utilization(address(usdc)), 0);
        assertEq(pool.borrowRate(address(usdc)), pool.BASE_RATE());
        assertEq(pool.liquidityRate(address(usdc)), 0);

        assertEq(pool.availableLiquidity(address(usdc)), usdc.balanceOf(address(supplyToken)));

        uint256 timePast = block.timestamp + 365 days;
        vm.warp(timePast);

        assertEq(pool.currentLiquidityIndex(address(usdc)), DecimalMath.WAD);
        assertEq(supplyToken.balanceOf(alice), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 1000e6);
        assertEq(pool.totalDebt(address(usdc)), 0);

        reserve = pool.getReserveData(address(usdc));
        assertEq(reserve.state.accruedToTreasury, 0);

        // 2d supply

        usdc.mint(alice, 500e6);
        assertEq(usdc.balanceOf(alice), 500e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 500e6);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Supplied(address(usdc), alice, alice, 500e6, 500e6);
        pool.supply(address(usdc), 500e6, alice);
        vm.stopPrank();

        reserve = pool.getReserveData(address(usdc));

        assertEq(reserve.state.accruedToTreasury, 0);
        assertEq(reserve.state.lastUpdateTimestamp, timePast);

        assertEq(pool.currentLiquidityIndex(address(usdc)), DecimalMath.WAD);
        assertEq(supplyToken.balanceOf(alice), 1500e6);
        assertEq(pool.totalSupply(address(usdc)), 1500e6);
        assertEq(pool.totalDebt(address(usdc)), 0);
    }

    function test_supply_usdc_weth() public {
        test_initReserve_weth_usdc();

        usdc.mint(alice, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Supplied(address(usdc), alice, alice, 1000e6, 1000e6);
        pool.supply(address(usdc), 1000e6, alice);
        vm.stopPrank();

        DataTypes.ReserveData memory reserveUsdc = pool.getReserveData(address(usdc));

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserveUsdc.supplyToken), 1000e6);

        weth.mint(alice, 3 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 2 ether);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Supplied(address(weth), alice, alice, 2 ether, 2 ether);
        pool.supply(address(weth), 2 ether, alice);
        vm.stopPrank();

        DataTypes.ReserveData memory reserveWeth = pool.getReserveData(address(weth));

        assertEq(weth.balanceOf(alice), 1 ether);
        assertEq(weth.balanceOf(address(pool)), 0e6);
        assertEq(weth.balanceOf(reserveWeth.supplyToken), 2 ether);

        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 1000e6);
        assertEq(pool.totalDebt(address(usdc)), 0);

        assertEq(pool.availableLiquidity(address(weth)), 2 ether);
        assertEq(pool.totalSupply(address(weth)), 2 ether);
        assertEq(pool.totalDebt(address(weth)), 0);

        assertEq(pool.utilization(address(usdc)), 0);
        assertEq(pool.utilization(address(weth)), 0);

        assertEq(pool.availableLiquidity(address(usdc)), usdc.balanceOf(address(reserveUsdc.supplyToken)));
        assertEq(pool.availableLiquidity(address(weth)), weth.balanceOf(address(reserveWeth.supplyToken)));
    }

    function test_supply_usdc_onBehalfOf() public {
        _setPoolAddresses();
        _setInitReserve(address(usdc));

        usdc.mint(alice, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Supplied(address(usdc), alice, bob, 1000e6, 1000e6);
        pool.supply(address(usdc), 1000e6, bob);
        vm.stopPrank();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 1000e6);

        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 1000e6);

        assertEq(pool.totalScaledDebt(address(usdc)), 0e6);
        assertEq(pool.totalDebt(address(usdc)), 0e6);

        ScaledSupplyToken supplyToken = ScaledSupplyToken(reserve.supplyToken);

        assertEq(supplyToken.scaledBalanceOf(bob), 1000e6);
        assertEq(supplyToken.balanceOf(bob), 1000e6);

        assertEq(pool.currentBorrowIndex(address(usdc)), reserve.state.borrowIndex);
        assertEq(pool.currentBorrowIndex(address(usdc)), DecimalMath.WAD);
        assertEq(pool.currentLiquidityIndex(address(usdc)), reserve.state.liquidityIndex);
        assertEq(pool.currentLiquidityIndex(address(usdc)), DecimalMath.WAD);

        assertEq(pool.utilization(address(usdc)), 0);
        assertEq(pool.borrowRate(address(usdc)), pool.BASE_RATE());
        assertEq(pool.liquidityRate(address(usdc)), 0);

        assertEq(pool.availableLiquidity(address(usdc)), usdc.balanceOf(address(supplyToken)));
    }

    function test_supply_reverts() public {
        _setPoolAddresses();
        _setInitReserve(address(usdc));

        usdc.mint(alice, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);

        assertEq(pool.totalSupply(address(usdc)), 0e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        vm.expectRevert(Pool.ZeroAddress.selector);
        pool.supply(address(0), 1000e6, alice);

        vm.expectRevert(Pool.ZeroAddress.selector);
        pool.supply(address(usdc), 1000e6, address(0));

        vm.expectRevert(Pool.ZeroAmount.selector);
        pool.supply(address(usdc), 0e6, alice);

        vm.expectRevert(); //ERC20InsufficientAllowance
        pool.supply(address(usdc), 1001e6, alice);

        usdc.approve(address(pool), 1001e6);
        vm.expectRevert(); //ERC20InsufficientBalance
        pool.supply(address(usdc), 1001e6, alice);

        assertEq(pool.totalSupply(address(usdc)), 0);
        assertEq(pool.totalScaledSupply(address(usdc)), 0);
        assertEq(pool.availableLiquidity(address(usdc)), 0);

        MockFeeOnTransferERC20 assetFeeOnTransfer = new MockFeeOnTransferERC20(bob, 10);

        assetFeeOnTransfer.mint(alice, 1 ether);
        assetFeeOnTransfer.approve(address(pool), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Pool.UnsupportedAsset.selector, address(assetFeeOnTransfer)));
        pool.supply(address(assetFeeOnTransfer), 1 ether, alice);
        vm.stopPrank();

        _setInitReserve(address(assetFeeOnTransfer));

        vm.prank(alice);

        vm.expectRevert(); //UnexpectedAmountReceived
        pool.supply(address(assetFeeOnTransfer), 1 ether, alice);

        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 0);

        assertEq(assetFeeOnTransfer.balanceOf(bob), 0); // feeOnTransferReceiver
        assertEq(assetFeeOnTransfer.balanceOf(alice), 1 ether);

        assertEq(pool.totalSupply(address(assetFeeOnTransfer)), 0);
        assertEq(pool.totalScaledSupply(address(assetFeeOnTransfer)), 0);
        assertEq(pool.availableLiquidity(address(assetFeeOnTransfer)), 0);
    }

    // function test_supply_revertsWhenSupplyTooSmall() public {
    //     _setPoolAddresses();
    //     _setInitReserve(address(usdc));

    //     usdc.mint(alice, 1000e6);
    //     assertEq(usdc.balanceOf(alice), 1000e6);

    //     vm.startPrank(alice);
    //     usdc.approve(address(pool), 1);
    //     vm.expectRevert(abi.encodeWithSelector(Pool.SupplyTooSmall.selector, 1));
    //     pool.supply(address(usdc), 1, alice);
    //     vm.stopPrank();
    // }

    function test_directDonation_isNotAccountedLiquidity() public {
        _setPoolAddresses();
        _setInitReserve(address(usdc));

        usdc.mint(alice, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        pool.supply(address(usdc), 1000e6, alice);
        vm.stopPrank();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 1000e6);

        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 1000e6);

        uint256 utilizationBefore = pool.utilization(address(usdc));
        uint256 borrowRateBefore = pool.borrowRate(address(usdc));

        usdc.mint(address(this), 100e6);
        usdc.transfer(reserve.supplyToken, 100e6);

        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(usdc.balanceOf(reserve.supplyToken), 1100e6);
        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(pool.unaccountedCash(address(usdc)), 100e6);

        assertEq(pool.totalScaledSupply(address(usdc)), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 1000e6);
        assertEq(pool.utilization(address(usdc)), utilizationBefore);
        assertEq(pool.borrowRate(address(usdc)), borrowRateBefore);
    }

    ///// Withdraw /////

    function test_withdraw_partial() public {
        _setPoolAddresses();
        _setInitReserve(address(usdc));

        usdc.mint(alice, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        pool.supply(address(usdc), 1000e6, alice);

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 1000e6);

        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 1000e6);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Withdrawn(address(usdc), alice, alice, 500e6, 500e6);
        pool.withdraw(address(usdc), 500e6, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 500e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 500e6);

        assertEq(pool.availableLiquidity(address(usdc)), 500e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 500e6);
        assertEq(pool.totalSupply(address(usdc)), 500e6);
    }

    function test_withdraw_fullMax() public {
        _setPoolAddresses();
        _setInitReserve(address(usdc));

        usdc.mint(alice, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        pool.supply(address(usdc), 1000e6, alice);

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 1000e6);

        assertEq(ScaledSupplyToken(reserve.supplyToken).balanceOf(alice), 1000e6);

        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 1000e6);

        uint256 withdrawn = type(uint256).max;

        vm.expectEmit(true, true, true, true, address(pool));
        emit Withdrawn(address(usdc), alice, alice, 1000e6, 1000e6);
        uint256 actualWithdrawn = pool.withdraw(address(usdc), type(uint256).max, alice);
        vm.stopPrank();

        assertEq(actualWithdrawn, 1000e6);
        assertEq(ScaledSupplyToken(reserve.supplyToken).balanceOf(alice), 0e6);

        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 0e6);

        assertEq(pool.availableLiquidity(address(usdc)), 0e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 0e6);
        assertEq(pool.totalSupply(address(usdc)), 0e6);
    }

    function test_withdraw_full() public {
        _setPoolAddresses();
        _setInitReserve(address(usdc));

        usdc.mint(alice, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        pool.supply(address(usdc), 1000e6, alice);

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 1000e6);

        assertEq(ScaledSupplyToken(reserve.supplyToken).balanceOf(alice), 1000e6);

        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 1000e6);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Withdrawn(address(usdc), alice, alice, 1000e6, 1000e6);
        uint256 actualWithdrawn = pool.withdraw(address(usdc), 1000e6, alice);
        vm.stopPrank();

        assertEq(actualWithdrawn, 1000e6);
        assertEq(ScaledSupplyToken(reserve.supplyToken).balanceOf(alice), 0e6);

        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 0e6);

        assertEq(pool.availableLiquidity(address(usdc)), 0e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 0e6);
        assertEq(pool.totalSupply(address(usdc)), 0e6);
    }

    function test_withdraw_partialTo() public {
        _setPoolAddresses();
        _setInitReserve(address(usdc));

        usdc.mint(alice, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        pool.supply(address(usdc), 1000e6, bob);
        vm.stopPrank();

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 1000e6);
        assertEq(ScaledSupplyToken(reserve.supplyToken).balanceOf(bob), 1000e6);

        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 1000e6);

        vm.startPrank(bob);
        vm.expectEmit(true, true, true, true, address(pool));
        emit Withdrawn(address(usdc), bob, alice, 500e6, 500e6);
        pool.withdraw(address(usdc), 500e6, alice);
        vm.stopPrank();

        reserve = pool.getReserveData(address(usdc));

        assertEq(usdc.balanceOf(alice), 500e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 500e6);

        assertEq(ScaledSupplyToken(reserve.supplyToken).balanceOf(bob), 500e6);

        assertEq(pool.availableLiquidity(address(usdc)), 500e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 500e6);
        assertEq(pool.totalSupply(address(usdc)), 500e6);
    }

    function test_withdraw_reverts() public {
        _setPoolAddresses();
        _setInitReserve(address(usdc));

        usdc.mint(alice, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        pool.supply(address(usdc), 1000e6, alice);

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 1000e6);

        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 1000e6);

        vm.expectRevert(Pool.ZeroAddress.selector);
        pool.withdraw(address(0), 500e6, alice);

        vm.expectRevert(Pool.ZeroAddress.selector);
        pool.withdraw(address(usdc), 500e6, address(0));

        vm.expectRevert(Pool.ZeroAmount.selector);
        pool.withdraw(address(usdc), 0e6, alice);

        vm.expectRevert(abi.encodeWithSelector(Pool.WithdrawExceedsSupply.selector, 1001e6, 1000e6));
        pool.withdraw(address(usdc), 1001e6, alice);

        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 1000e6);

        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 1000e6);
    }

    function test_transferUnderlyingTo_revertsWhenNotPool() public {
        _setPoolAddresses();
        _setInitReserve(address(usdc));

        usdc.mint(alice, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        pool.supply(address(usdc), 1000e6, alice);

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 1000e6);

        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 1000e6);

        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyToken.OnlyPool.selector, alice));
        ScaledSupplyToken(reserve.supplyToken).transferUnderlyingTo(alice, 1000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);
        assertEq(usdc.balanceOf(reserve.supplyToken), 1000e6);

        assertEq(pool.availableLiquidity(address(usdc)), 1000e6);
        assertEq(pool.totalScaledSupply(address(usdc)), 1000e6);
        assertEq(pool.totalSupply(address(usdc)), 1000e6);
    }

    ///// supply and withdrawal rounding above WAD /////

    function _prepareUsdcAtRaisedIndex() internal returns (ScaledSupplyToken supplyToken) {
        _setPoolAddresses();
        _setInitReserve(address(usdc));

        PoolHarness(address(pool)).setLiquidityIndexForTest(address(usdc), 1.5e18);

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));

        supplyToken = ScaledSupplyToken(reserve.supplyToken);
    }

    // | Operation with index = `1.5e18`| Expected result                   |
    // |---                             |---                                |
    // | Supply `10`                    | `floor(10 / 1.5) = 6` shares      |
    // | Supply `12`                    | `8` shares                        |
    // | Partial withdraw `2`           | `ceil(2 / 1.5) = 2` shares burned |
    // | Supply `1`                     | `0` shares → revert               |
    function test_supply_roundsDownAtRaisedIndex() public {
        ScaledSupplyToken supplyToken = _prepareUsdcAtRaisedIndex();

        _supplyAliceUsdc(10);

        assertEq(supplyToken.scaledBalanceOf(alice), 6);
        assertEq(supplyToken.balanceOf(alice), 9);
        assertEq(pool.totalScaledSupply(address(usdc)), 6);
        assertEq(pool.totalSupply(address(usdc)), 9);

        assertEq(pool.availableLiquidity(address(usdc)), 10);
        assertEq(usdc.balanceOf(address(supplyToken)), 10);
        assertEq(pool.unaccountedCash(address(usdc)), 0);
    }

    function test_withdraw_roundsUpAtRaisedIndex() public {
        ScaledSupplyToken supplyToken = _prepareUsdcAtRaisedIndex();

        _supplyAliceUsdc(12);

        vm.prank(alice);
        uint256 withdrawn = pool.withdraw(address(usdc), 2, alice);

        assertEq(withdrawn, 2);
        assertEq(usdc.balanceOf(alice), 2);

        // There were 8 shares; ceil(2 / 1.5) = 2 burned
        assertEq(supplyToken.scaledBalanceOf(alice), 6);
        assertEq(supplyToken.balanceOf(alice), 9);
        assertEq(pool.totalScaledSupply(address(usdc)), 6);
        assertEq(pool.totalSupply(address(usdc)), 9);

        assertEq(pool.availableLiquidity(address(usdc)), 10);
        assertEq(usdc.balanceOf(address(supplyToken)), 10);
    }

    function test_withdraw_fullAtRaisedIndex() public {
        ScaledSupplyToken supplyToken = _prepareUsdcAtRaisedIndex();

        _supplyAliceUsdc(10);

        vm.prank(alice);
        uint256 withdrawn = pool.withdraw(address(usdc), type(uint256).max, alice);

        assertEq(withdrawn, 9);
        assertEq(usdc.balanceOf(alice), 9);
        assertEq(supplyToken.scaledBalanceOf(alice), 0);
        assertEq(supplyToken.balanceOf(alice), 0);
        assertEq(pool.totalScaledSupply(address(usdc)), 0);

        assertEq(pool.availableLiquidity(address(usdc)), 1);
        assertEq(usdc.balanceOf(address(supplyToken)), 1);
        assertEq(pool.unaccountedCash(address(usdc)), 0);
    }

    function test_supply_revertsWhenScaledAmountIsZero() public {
        ScaledSupplyToken supplyToken = _prepareUsdcAtRaisedIndex();

        usdc.mint(alice, 1);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1);

        vm.expectRevert(abi.encodeWithSelector(Pool.SupplyTooSmall.selector, 1));
        pool.supply(address(usdc), 1, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 1);
        assertEq(usdc.balanceOf(address(supplyToken)), 0);
        assertEq(supplyToken.scaledBalanceOf(alice), 0);
        assertEq(pool.availableLiquidity(address(usdc)), 0);
    }

    ///// Reserve Configuration /////

    function test_configureReserve_borrowingDisabled() public {
        _setPoolAddresses();
        _setInitReserveWeth();
        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));
        assertTrue(reserve.initialized);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ReserveConfigured(address(weth), 0.75e18, 0.8e18, false);
        configurator.configureReserve(address(weth), 0.75e18, 0.8e18, false);

        reserve = pool.getReserveData(address(weth));
        assertEq(reserve.configuration.ltvWad, 0.75e18);
        assertEq(reserve.configuration.liquidationThresholdWad, 0.8e18);
        assertFalse(reserve.configuration.borrowingEnabled);
    }

    function test_configureReserve_update() public {
        _setPoolAddresses();
        _setInitReserveWeth();

        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ReserveConfigured(address(weth), 0.75e18, 0.8e18, false);
        configurator.configureReserve(address(weth), 0.75e18, 0.8e18, false);

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));
        assertEq(reserve.configuration.ltvWad, 0.75e18);
        assertEq(reserve.configuration.liquidationThresholdWad, 0.8e18);
        assertFalse(reserve.configuration.borrowingEnabled);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ReserveConfigured(address(weth), 0.77e18, 0.85e18, true);
        configurator.configureReserve(address(weth), 0.77e18, 0.85e18, true);

        reserve = pool.getReserveData(address(weth));
        assertEq(reserve.configuration.ltvWad, 0.77e18);
        assertEq(reserve.configuration.liquidationThresholdWad, 0.85e18);
        assertTrue(reserve.configuration.borrowingEnabled);
    }

    function _setInitReserveUsdc() internal {
        vm.prank(admin);
        configurator.initReserve(address(usdc));

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));
        assertTrue(reserve.initialized);
    }

    function _setPoolAndInitReserveWeth() internal {
        _setPoolAddresses();
        _setInitReserveWeth();
    }

    function _setInitAndConfigReserveWeth() internal {
        _setPoolAddresses();
        _setInitReserveWeth();
        vm.prank(admin);
        configurator.configureReserve(address(weth), 0.75e18, 0.8e18, false);
    }

    function test_configureReserve_borrowingEnabled_additionalAsset() public {
        _setInitAndConfigReserveWeth();

        _setInitReserveUsdc();
        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));
        assertTrue(reserve.initialized);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ReserveConfigured(address(usdc), 0, 0, true);
        configurator.configureReserve(address(usdc), 0, 0, true);

        reserve = pool.getReserveData(address(weth));
        assertEq(reserve.configuration.ltvWad, 0.75e18);
        assertEq(reserve.configuration.liquidationThresholdWad, 0.8e18);
        assertFalse(reserve.configuration.borrowingEnabled);

        reserve = pool.getReserveData(address(usdc));
        assertEq(reserve.configuration.ltvWad, 0);
        assertEq(reserve.configuration.liquidationThresholdWad, 0);
        assertTrue(reserve.configuration.borrowingEnabled);
    }

    function test_configureReserve_borrowingEnabled() public {
        _setPoolAddresses();
        _setInitReserveUsdc();
        DataTypes.ReserveData memory reserve = pool.getReserveData(address(usdc));
        assertTrue(reserve.initialized);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ReserveConfigured(address(usdc), 0, 0.8e18, true);
        configurator.configureReserve(address(usdc), 0, 0.8e18, true);

        reserve = pool.getReserveData(address(usdc));
        assertEq(reserve.configuration.ltvWad, 0);
        assertEq(reserve.configuration.liquidationThresholdWad, 0.8e18);
        assertTrue(reserve.configuration.borrowingEnabled);
    }

    function test_configureReserve_reverts() public {
        _setPoolAddresses();
        _setInitReserveWeth();

        vm.expectRevert(); //OwnableUnauthorizedAccount
        configurator.configureReserve(address(weth), 0.75e18, 0.8e18, false);

        vm.prank(admin);
        vm.expectRevert(PoolConfigurator.ZeroAddress.selector);
        configurator.configureReserve(address(0), 0.75e18, 0.8e18, false);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Pool.InvalidUnderlying.selector, alice));
        configurator.configureReserve(address(alice), 0.75e18, 0.8e18, false);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Pool.OnlyConfigurator.selector, admin));
        pool.configureReserve(address(weth), 0.75e18, 0.8e18, false);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Pool.UnsupportedAsset.selector, address(usdc)));
        configurator.configureReserve(address(usdc), 0.75e18, 0.8e18, false);

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));
        assertEq(reserve.configuration.ltvWad, 0);
        assertEq(reserve.configuration.liquidationThresholdWad, 0);
        assertFalse(reserve.configuration.borrowingEnabled);
    }

    function test_configureReserve_revertsWhenInvalidParams() public {
        _setInitAndConfigReserveWeth();
        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));
        assertEq(reserve.configuration.ltvWad, 0.75e18);
        assertEq(reserve.configuration.liquidationThresholdWad, 0.8e18);
        assertFalse(reserve.configuration.borrowingEnabled);

        vm.prank(admin);
        vm.expectRevert(Pool.InvalidParams.selector);
        configurator.configureReserve(address(weth), 0.81e18, 0.8e18, false);

        vm.prank(admin);
        vm.expectRevert(Pool.InvalidParams.selector);
        configurator.configureReserve(address(weth), 0.79e18, DecimalMath.WAD + 1, false);

        vm.prank(admin);
        vm.expectRevert(Pool.InvalidParams.selector);
        configurator.configureReserve(address(weth), 0.79e18, 0, false);

        reserve = pool.getReserveData(address(weth));
        assertEq(reserve.configuration.ltvWad, 0.75e18);
        assertEq(reserve.configuration.liquidationThresholdWad, 0.8e18);
        assertFalse(reserve.configuration.borrowingEnabled);
    }

    ////// setUserUseReserveAsCollateral /////

    function test_setUserUseReserveAsCollateral() public {
        _setInitAndConfigReserveWeth();
        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));
        assertEq(reserve.configuration.ltvWad, 0.75e18);
        assertEq(reserve.configuration.liquidationThresholdWad, 0.8e18);
        assertFalse(reserve.configuration.borrowingEnabled);

        assertFalse(pool.isUsingAsCollateral(alice, address(weth)));

        weth.mint(alice, 3 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 2 ether);
        pool.supply(address(weth), 2 ether, alice);

        DataTypes.ReserveData memory reserveWeth = pool.getReserveData(address(weth));

        assertEq(weth.balanceOf(alice), 1 ether);
        assertEq(weth.balanceOf(reserveWeth.supplyToken), 2 ether);

        assertEq(pool.availableLiquidity(address(weth)), 2 ether);
        assertEq(pool.totalSupply(address(weth)), 2 ether);

        assertEq(ScaledSupplyToken(reserveWeth.supplyToken).balanceOf(alice), 2 ether);

        vm.expectEmit(true, true, false, true, address(pool));
        emit UserCollateralUsageChanged(alice, address(weth), true);
        pool.setUserUseReserveAsCollateral(address(weth), true);

        vm.stopPrank();

        reserveWeth = pool.getReserveData(address(weth));

        assertEq(ScaledSupplyToken(reserveWeth.supplyToken).balanceOf(alice), 2 ether);

        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));
    }

    function test_setUserUseReserveAsCollateral_reserts() public {
        assertFalse(pool.isUsingAsCollateral(alice, address(weth)));

        _setPoolAndInitReserveWeth();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Pool.CollateralNotEnabled.selector, address(weth)));
        pool.setUserUseReserveAsCollateral(address(weth), true);

        vm.prank(admin);
        configurator.configureReserve(address(weth), 0.75e18, 0.8e18, false);
        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));
        assertEq(reserve.configuration.ltvWad, 0.75e18);
        assertEq(reserve.configuration.liquidationThresholdWad, 0.8e18);
        assertFalse(reserve.configuration.borrowingEnabled);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Pool.NoSupplyPosition.selector, alice, address(weth)));
        pool.setUserUseReserveAsCollateral(address(weth), true);

        assertFalse(pool.isUsingAsCollateral(alice, address(weth)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Pool.UnsupportedAsset.selector, address(usdc)));
        pool.setUserUseReserveAsCollateral(address(usdc), true);

        assertFalse(pool.isUsingAsCollateral(alice, address(weth)));
    }

    function test_setUserUseReserveAsCollateral_disableAfterSetThresholdToZero_disableAgain() public {
        _setPoolAddresses();
        _setInitReserveWeth();
        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));
        assertTrue(reserve.initialized);

        vm.prank(admin);
        configurator.configureReserve(address(weth), 0.75e18, 0.8e18, false);

        reserve = pool.getReserveData(address(weth));
        assertEq(reserve.configuration.ltvWad, 0.75e18);
        assertEq(reserve.configuration.liquidationThresholdWad, 0.8e18);
        assertFalse(reserve.configuration.borrowingEnabled);

        weth.mint(alice, 3 ether);
        vm.startPrank(alice);
        weth.approve(address(pool), 3 ether);
        pool.supply(address(weth), 3 ether, alice);

        pool.setUserUseReserveAsCollateral(address(weth), true);
        vm.stopPrank();

        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        // Check No-op: no emit behaviour
        vm.recordLogs();

        vm.prank(alice);
        pool.setUserUseReserveAsCollateral(address(weth), true);

        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        vm.prank(admin);
        configurator.configureReserve(address(weth), 0, 0, false);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(pool));
        emit UserCollateralUsageChanged(alice, address(weth), false);
        pool.setUserUseReserveAsCollateral(address(weth), false);

        assertFalse(pool.isUsingAsCollateral(alice, address(weth)));

        vm.recordLogs();
        vm.prank(alice);
        pool.setUserUseReserveAsCollateral(address(weth), false);

        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(pool.isUsingAsCollateral(alice, address(weth)));
    }

    function test_setUserUseReserveAsCollateral_independetUsersFlags_twoUsers() public {
        _setInitAndConfigReserveWeth();
        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));
        assertEq(reserve.configuration.ltvWad, 0.75e18);
        assertEq(reserve.configuration.liquidationThresholdWad, 0.8e18);
        assertFalse(reserve.configuration.borrowingEnabled);

        assertFalse(pool.isUsingAsCollateral(alice, address(weth)));

        weth.mint(alice, 3 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 2 ether);
        pool.supply(address(weth), 2 ether, alice);

        DataTypes.ReserveData memory reserveWeth = pool.getReserveData(address(weth));

        assertEq(weth.balanceOf(alice), 1 ether);
        assertEq(weth.balanceOf(reserveWeth.supplyToken), 2 ether);

        assertEq(pool.availableLiquidity(address(weth)), 2 ether);
        assertEq(pool.totalSupply(address(weth)), 2 ether);

        assertEq(ScaledSupplyToken(reserveWeth.supplyToken).balanceOf(alice), 2 ether);

        vm.expectEmit(true, true, false, true, address(pool));
        emit UserCollateralUsageChanged(alice, address(weth), true);
        pool.setUserUseReserveAsCollateral(address(weth), true);

        vm.stopPrank();

        reserveWeth = pool.getReserveData(address(weth));

        assertEq(ScaledSupplyToken(reserveWeth.supplyToken).balanceOf(alice), 2 ether);

        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        weth.mint(bob, 2 ether);
        vm.startPrank(bob);
        weth.approve(address(pool), 2 ether);
        pool.supply(address(weth), 2 ether, bob);

        pool.setUserUseReserveAsCollateral(address(weth), true);

        assertTrue(pool.isUsingAsCollateral(bob, address(weth)));
        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        reserveWeth = pool.getReserveData(address(weth));

        assertEq(weth.balanceOf(bob), 0 ether);
        assertEq(weth.balanceOf(reserveWeth.supplyToken), 4 ether);

        assertEq(pool.availableLiquidity(address(weth)), 4 ether);
        assertEq(pool.totalSupply(address(weth)), 4 ether);

        assertEq(ScaledSupplyToken(reserveWeth.supplyToken).balanceOf(bob), 2 ether);

        vm.expectEmit(true, true, false, true, address(pool));
        emit UserCollateralUsageChanged(bob, address(weth), false);
        pool.setUserUseReserveAsCollateral(address(weth), false);

        vm.stopPrank();

        assertFalse(pool.isUsingAsCollateral(bob, address(weth)));

        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));
    }

    function test_setUserUseReserveAsCollateral_independetUsersFlags_oneUser() public {
        _setInitAndConfigReserveWeth();
        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));
        assertEq(reserve.configuration.ltvWad, 0.75e18);
        assertEq(reserve.configuration.liquidationThresholdWad, 0.8e18);
        assertFalse(reserve.configuration.borrowingEnabled);

        assertFalse(pool.isUsingAsCollateral(alice, address(weth)));

        weth.mint(alice, 3 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 2 ether);
        pool.supply(address(weth), 2 ether, alice);

        DataTypes.ReserveData memory reserveWeth = pool.getReserveData(address(weth));

        assertEq(weth.balanceOf(alice), 1 ether);
        assertEq(weth.balanceOf(reserveWeth.supplyToken), 2 ether);

        assertEq(pool.availableLiquidity(address(weth)), 2 ether);
        assertEq(pool.totalSupply(address(weth)), 2 ether);

        assertEq(ScaledSupplyToken(reserveWeth.supplyToken).balanceOf(alice), 2 ether);

        vm.expectEmit(true, true, false, true, address(pool));
        emit UserCollateralUsageChanged(alice, address(weth), true);
        pool.setUserUseReserveAsCollateral(address(weth), true);

        vm.stopPrank();

        reserveWeth = pool.getReserveData(address(weth));

        assertEq(ScaledSupplyToken(reserveWeth.supplyToken).balanceOf(alice), 2 ether);

        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        _setInitReserveUsdc();
        vm.prank(admin);
        configurator.configureReserve(address(usdc), 0.75e18, 0.8e18, true);

        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.supply(address(usdc), 1000e6, alice);

        pool.setUserUseReserveAsCollateral(address(usdc), true);

        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));
        assertTrue(pool.isUsingAsCollateral(alice, address(usdc)));

        reserveWeth = pool.getReserveData(address(weth));
        DataTypes.ReserveData memory reserveUsdc = pool.getReserveData(address(usdc));

        assertEq(weth.balanceOf(reserveWeth.supplyToken), 2 ether);
        assertEq(usdc.balanceOf(reserveUsdc.supplyToken), 1000e6);

        vm.expectEmit(true, true, false, true, address(pool));
        emit UserCollateralUsageChanged(alice, address(usdc), false);
        pool.setUserUseReserveAsCollateral(address(usdc), false);

        vm.stopPrank();

        assertFalse(pool.isUsingAsCollateral(alice, address(usdc)));
        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));
    }

    function test_withdraw_preservesThenClearsCollateralFlag() public {
        _setInitAndConfigReserveWeth();

        weth.mint(alice, 1 ether);
        assertEq(weth.balanceOf(alice), 1 ether);

        vm.startPrank(alice);
        weth.approve(address(pool), 1 ether);

        pool.supply(address(weth), 1 ether, alice);

        pool.setUserUseReserveAsCollateral(address(weth), true);

        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        DataTypes.ReserveData memory reserve = pool.getReserveData(address(weth));

        assertEq(weth.balanceOf(reserve.supplyToken), 1 ether);

        assertEq(ScaledSupplyToken(reserve.supplyToken).balanceOf(alice), 1 ether);

        pool.withdraw(address(weth), 0.5 ether, alice);

        reserve = pool.getReserveData(address(weth));

        assertTrue(pool.isUsingAsCollateral(alice, address(weth)));

        assertEq(weth.balanceOf(reserve.supplyToken), 0.5 ether);

        assertEq(ScaledSupplyToken(reserve.supplyToken).balanceOf(alice), 0.5 ether);

        assertEq(weth.balanceOf(alice), 0.5 ether);

        pool.withdraw(address(weth), type(uint256).max, alice);
        vm.stopPrank();

        reserve = pool.getReserveData(address(weth));

        assertFalse(pool.isUsingAsCollateral(alice, address(weth)));

        assertEq(weth.balanceOf(reserve.supplyToken), 0 ether);

        assertEq(ScaledSupplyToken(reserve.supplyToken).balanceOf(alice), 0 ether);

        assertEq(weth.balanceOf(alice), 1 ether);
    }

    function test_withdraw_fullAtRaisedIndex_clearsCollateralFlag() public {
        ScaledSupplyToken supplyToken = _prepareUsdcAtRaisedIndex();

        _supplyAliceUsdc(12);

        vm.prank(admin);
        configurator.configureReserve(address(usdc), 0.75e18, 0.8e18, true);

        vm.startPrank(alice);

        pool.setUserUseReserveAsCollateral(address(usdc), true);
        assertTrue(pool.isUsingAsCollateral(alice, address(usdc)));

        uint256 withdrawn = pool.withdraw(address(usdc), type(uint256).max, alice);

        vm.stopPrank();

        assertEq(withdrawn, 12);
        assertEq(supplyToken.scaledBalanceOf(alice), 0);
        assertFalse(pool.isUsingAsCollateral(alice, address(usdc)));
    }
}

