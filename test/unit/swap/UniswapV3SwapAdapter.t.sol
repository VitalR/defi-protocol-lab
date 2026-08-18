// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { UniswapV3SwapAdapter, ISwapAdapter } from "src/labs/swaps/adapters/UniswapV3SwapAdapter.sol";
import { MockUniswapV3SwapRouter } from "test/mocks/MockUniswapV3SwapRouter.sol";
import { MockWETH } from "test/mocks/MockWETH.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";

contract UniswapV3SwapAdapterTest is Test {
    UniswapV3SwapAdapter adapter;
    MockUniswapV3SwapRouter router;
    MockWETH mockWETH;
    MockUSDC mockUSDC;

    address user = address(0x1001);
    uint256 initialETHBalance = 10 ether;

    function setUp() public {
        router = new MockUniswapV3SwapRouter();
        adapter = new UniswapV3SwapAdapter(address(router));

        mockUSDC = new MockUSDC();
        mockUSDC.mint(address(router), 100_000e6);

        mockWETH = new MockWETH();
        mockWETH.mint(user, initialETHBalance);
    }

    function test_deployment_constructorConfiguration() public {
        assertEq(address(adapter.router()), address(router));
    }

    function test_deployment_reverts_constructorConfiguration() public {
        vm.expectRevert(UniswapV3SwapAdapter.InvalidRouter.selector);
        adapter = new UniswapV3SwapAdapter(address(0));

        address eoa = address(0x1002);
        vm.expectRevert(UniswapV3SwapAdapter.InvalidRouter.selector);
        adapter = new UniswapV3SwapAdapter(eoa);
    }

    function test_swapExactInput_singleHop() public {
        uint256 deadline = block.timestamp + 30 minutes;
        uint256 amountOut = 1950e6;
        router.setAmountOut(amountOut);

        uint24 fee = 3000;
        uint256 swapAmount = 1 ether;

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), swapAmount);

        uint256 receivedAmount = adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountIn: swapAmount,
                minAmountOut: amountOut,
                recipient: user,
                deadline: deadline,
                route: abi.encode(fee)
            })
        );

        vm.stopPrank();

        assertEq(receivedAmount, amountOut);
        assertEq(mockUSDC.balanceOf(user), amountOut);
        assertEq(mockWETH.balanceOf(user), initialETHBalance - swapAmount);
        assertEq(mockWETH.balanceOf(address(router)), swapAmount);

        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);

        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);

        assertEq(router.lastTokenIn(), address(mockWETH));
        assertEq(router.lastTokenOut(), address(mockUSDC));
        assertEq(router.lastFee(), 3000);
        assertEq(router.lastRecipient(), user);
        assertEq(router.lastAmountIn(), swapAmount);
        assertEq(router.lastAmountOutMinimum(), amountOut);
    }

    // User pull
    // → Adapter approval
    // → Router state changes
    // → token transfers
    // → Adapter revert
    //             ↓
    // ALL state rolls back
    function test_swapExactInput_reverts_whenOutputBelowMinimum() public {
        uint256 deadline = block.timestamp + 30 minutes;
        uint256 amountOut = 1850e6;
        router.setAmountOut(amountOut);

        uint24 fee = 3000;
        uint256 swapAmount = 1 ether;
        uint256 minAmountOut = 1900e6;

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), swapAmount);

        vm.expectRevert(
            abi.encodeWithSelector(UniswapV3SwapAdapter.InsufficientAmountOut.selector, minAmountOut, amountOut)
        );

        uint256 receivedAmount = adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountIn: swapAmount,
                minAmountOut: minAmountOut,
                recipient: user,
                deadline: deadline,
                route: abi.encode(fee)
            })
        );

        vm.stopPrank();

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);
        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);
        assertEq(router.lastTokenIn(), address(0));
        assertEq(router.lastTokenOut(), address(0));
        assertEq(router.lastFee(), 0);
        assertEq(router.lastRecipient(), address(0));
        assertEq(router.lastAmountIn(), 0);
        assertEq(router.lastAmountOutMinimum(), 0);
    }

    function test_swapExactInput_propagatesRouterRevert() public {
        uint256 deadline = block.timestamp + 30 minutes;
        uint256 amountOut = 1850e6;
        router.setAmountOut(amountOut);
        router.setShouldRevert(true);

        uint24 fee = 3000;
        uint256 swapAmount = 1 ether;
        uint256 minAmountOut = 1900e6;

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), swapAmount);

        vm.expectRevert(MockUniswapV3SwapRouter.MockRouterRevert.selector);

        uint256 receivedAmount = adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountIn: swapAmount,
                minAmountOut: minAmountOut,
                recipient: user,
                deadline: deadline,
                route: abi.encode(fee)
            })
        );

        vm.stopPrank();

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);
        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);
        assertEq(router.lastTokenIn(), address(0));
        assertEq(router.lastTokenOut(), address(0));
        assertEq(router.lastFee(), 0);
        assertEq(router.lastRecipient(), address(0));
        assertEq(router.lastAmountIn(), 0);
        assertEq(router.lastAmountOutMinimum(), 0);
    }

    function test_swapExactInput_reverts_whenTokenInZero() public {
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1 ether);

        vm.expectRevert(UniswapV3SwapAdapter.ZeroAddress.selector);
        adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(0),
                tokenOut: address(mockUSDC),
                amountIn: 1 ether,
                minAmountOut: 1980e6,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
    }

    function test_swapExactInput_reverts_whenTokenOutZero() public {
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1 ether);

        vm.expectRevert(UniswapV3SwapAdapter.ZeroAddress.selector);
        adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(0),
                amountIn: 1 ether,
                minAmountOut: 1980e6,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
    }

    function test_swapExactInput_reverts_whenRecipientZero() public {
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1 ether);

        vm.expectRevert(UniswapV3SwapAdapter.ZeroAddress.selector);
        adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountIn: 1 ether,
                minAmountOut: 1980e6,
                recipient: address(0),
                deadline: block.timestamp + 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
    }

    function test_swapExactInput_reverts_whenSameToken() public {
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1 ether);

        vm.expectRevert(UniswapV3SwapAdapter.SameToken.selector);
        adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockWETH),
                amountIn: 1 ether,
                minAmountOut: 1980e6,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
    }

    function test_swapExactInput_reverts_whenZeroAmountIn() public {
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1 ether);

        vm.expectRevert(UniswapV3SwapAdapter.ZeroAmountIn.selector);
        adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountIn: 0,
                minAmountOut: 1980e6,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
    }

    function test_swapExactInput_reverts_whenZeroMinAmountOut() public {
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1 ether);

        vm.expectRevert(UniswapV3SwapAdapter.ZeroMinAmountOut.selector);
        adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountIn: 1 ether,
                minAmountOut: 0,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
    }

    function test_swapExactInput_reverts_whenExpiredSwap() public {
        skip(1 days);
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1 ether);

        vm.expectRevert(UniswapV3SwapAdapter.ExpiredSwap.selector);
        adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountIn: 1 ether,
                minAmountOut: 1980e6,
                recipient: user,
                deadline: block.timestamp - 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
    }

    function test_swapExactInput_reverts_whenInvalidRoute() public {
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        bytes memory invalidRoute = "0";

        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1 ether);

        vm.expectRevert(UniswapV3SwapAdapter.InvalidRoute.selector);
        adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountIn: 1 ether,
                minAmountOut: 1980e6,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: invalidRoute
            })
        );

        vm.stopPrank();
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
    }

    function test_swapExactInput_allowsDeadlineAtCurrentTimestamp() public {
        uint256 deadline = block.timestamp;
        uint256 amountOut = 1950e6;
        router.setAmountOut(amountOut);

        uint24 fee = 3000;
        uint256 swapAmount = 1 ether;

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), swapAmount);

        uint256 receivedAmount = adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountIn: swapAmount,
                minAmountOut: amountOut,
                recipient: user,
                deadline: deadline,
                route: abi.encode(fee)
            })
        );

        vm.stopPrank();

        assertEq(receivedAmount, amountOut);
        assertEq(mockUSDC.balanceOf(user), amountOut);
        assertEq(mockWETH.balanceOf(user), initialETHBalance - swapAmount);
        assertEq(mockWETH.balanceOf(address(router)), swapAmount);

        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);

        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);

        assertEq(router.lastTokenIn(), address(mockWETH));
        assertEq(router.lastTokenOut(), address(mockUSDC));
        assertEq(router.lastFee(), 3000);
        assertEq(router.lastRecipient(), user);
        assertEq(router.lastAmountIn(), swapAmount);
        assertEq(router.lastAmountOutMinimum(), amountOut);
    }
}
