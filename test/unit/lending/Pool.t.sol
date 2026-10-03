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

    function setUp() public {
        provider = new PoolAddressProvider(admin);
        configurator = new PoolConfigurator(admin, address(provider));
        pool = new Pool(address(provider));
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

    function test_initReserve_weth_usdc() public {
        test_initReserve_weth();
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
        vm.expectRevert(Pool.ZeroAddress.selector);
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
}

