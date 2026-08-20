// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { UniswapV3SwapAdapter, ISwapAdapter } from "src/labs/swaps/adapters/UniswapV3SwapAdapter.sol";
import { MockUniswapV3SwapRouter } from "test/mocks/MockUniswapV3SwapRouter.sol";
import { MockWETH } from "test/mocks/MockWETH.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";
import { MockWBTC } from "test/mocks/MockWBTC.sol";

contract UniswapV3SwapAdapterTest is Test {
    UniswapV3SwapAdapter adapter;
    MockUniswapV3SwapRouter router;
    MockWETH mockWETH;
    MockUSDC mockUSDC;
    MockWBTC mockWBTC;

    address user = address(0x1001);
    uint256 initialETHBalance = 10 ether;

    function setUp() public {
        router = new MockUniswapV3SwapRouter();
        adapter = new UniswapV3SwapAdapter(address(router));

        mockUSDC = new MockUSDC();
        mockUSDC.mint(address(router), 100_000e6);

        mockWETH = new MockWETH();
        mockWETH.mint(user, initialETHBalance);

        mockWBTC = new MockWBTC();
        mockWBTC.mint(address(router), 5e8);
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

    function test_swapExactInput_multihopPath() public {
        // Suppose:
        // 1 WETH ≈ $1,950
        // 1 BTC  ≈ $30,000
        // => 1950 / 30000 ≈ 0.065 BTC =>

        uint256 amountOut = 0.065e8;
        uint256 swapAmount = 1 ether;

        router.setAmountOut(amountOut);
        router.setMultihopTokens(address(mockWETH), address(mockWBTC));

        assertEq(mockWBTC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), swapAmount);

        uint256 receivedAmount = adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockWBTC),
                amountIn: swapAmount,
                minAmountOut: amountOut,
                recipient: user,
                deadline: block.timestamp,
                route: abi.encodePacked(
                    address(mockWETH), uint24(3000), address(mockUSDC), uint24(500), address(mockWBTC)
                )
            })
        );

        vm.stopPrank();

        assertEq(receivedAmount, amountOut);
        assertEq(mockWBTC.balanceOf(user), amountOut);
        assertEq(mockWETH.balanceOf(user), initialETHBalance - swapAmount);
        assertEq(mockWETH.balanceOf(address(router)), swapAmount);

        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockWBTC.balanceOf(address(adapter)), 0);

        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);

        assertEq(router.lastRecipient(), user);
        assertEq(router.lastAmountIn(), swapAmount);
        assertEq(router.lastAmountOutMinimum(), amountOut);
    }

    function test_swapExactInput_multihopPath_reverts_whenInsufficientAmountOut() public {
        // Suppose:
        // 1 WETH ≈ $1,950
        // 1 BTC  ≈ $30,000
        // => 1950 / 30000 ≈ 0.065 BTC =>

        uint256 amountOut = 0.065e8;
        uint256 swapAmount = 1 ether;

        router.setAmountOut(0.06e8); // < amountOut
        router.setMultihopTokens(address(mockWETH), address(mockWBTC));

        assertEq(mockWBTC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), swapAmount);

        vm.expectRevert(abi.encodeWithSelector(UniswapV3SwapAdapter.InsufficientAmountOut.selector, amountOut, 0.06e8));

        adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockWBTC),
                amountIn: swapAmount,
                minAmountOut: amountOut,
                recipient: user,
                deadline: block.timestamp,
                route: abi.encodePacked(
                    address(mockWETH), uint24(3000), address(mockUSDC), uint24(500), address(mockWBTC)
                )
            })
        );

        vm.stopPrank();

        assertEq(mockWBTC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
    }

    function test_swapExactInput_multihopPath_reverts_propagatesRouterRevert() public {
        uint256 amountOut = 0.065e8;
        uint256 swapAmount = 1 ether;

        router.setAmountOut(amountOut);
        router.setMultihopTokens(address(mockWETH), address(mockWBTC));
        router.setShouldRevert(true);

        assertEq(mockWBTC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), swapAmount);

        vm.expectRevert(MockUniswapV3SwapRouter.MockRouterRevert.selector);

        adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockWBTC),
                amountIn: swapAmount,
                minAmountOut: amountOut,
                recipient: user,
                deadline: block.timestamp,
                route: abi.encodePacked(
                    address(mockWETH), uint24(3000), address(mockUSDC), uint24(500), address(mockWBTC)
                )
            })
        );

        vm.stopPrank();

        assertEq(mockWBTC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
    }

    function test_swapExactInput_multihopPath_reverts_whenBelowValidPath() public {
        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1 ether);

        vm.expectRevert(UniswapV3SwapAdapter.InvalidRoute.selector);

        adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockWBTC),
                amountIn: 1 ether,
                minAmountOut: 0.5e8,
                recipient: user,
                deadline: block.timestamp,
                route: abi.encodePacked(address(mockWETH), uint24(3000), address(mockUSDC), uint8(0), address(mockWBTC))
            })
        );
        // route: 20 + 3 + 20 + 1 + 20 = 64 bytes

        vm.stopPrank();
    }

    function test_swapExactInput_multihopPath_reverts_whenAboveValidPath() public {
        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1 ether);

        vm.expectRevert(UniswapV3SwapAdapter.InvalidRoute.selector);

        adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockWBTC),
                amountIn: 1 ether,
                minAmountOut: 0.5e8,
                recipient: user,
                deadline: block.timestamp,
                route: abi.encodePacked(
                    address(mockWETH), uint24(3000), address(mockUSDC), uint32(500), address(mockWBTC)
                )
            })
        );
        // route: 20 + 3 + 20 + 4 + 20 = 67 bytes

        vm.stopPrank();
    }

    function test_swapExactInput_multihopPath_reverts_whenTokenInMismatch() public {
        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1 ether);

        vm.expectRevert(UniswapV3SwapAdapter.TokenMismatch.selector);

        adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockWBTC),
                amountIn: 1 ether,
                minAmountOut: 0.5e8,
                recipient: user,
                deadline: block.timestamp,
                route: abi.encodePacked(
                    address(mockUSDC), uint24(3000), address(mockUSDC), uint24(500), address(mockWBTC)
                )
            })
        );

        vm.stopPrank();
    }

    function test_swapExactInput_multihopPath_reverts_whenTokenOutMismatch() public {
        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1 ether);

        vm.expectRevert(UniswapV3SwapAdapter.TokenMismatch.selector);

        adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockWBTC),
                amountIn: 1 ether,
                minAmountOut: 0.5e8,
                recipient: user,
                deadline: block.timestamp,
                route: abi.encodePacked(
                    address(mockWETH), uint24(3000), address(mockUSDC), uint24(500), address(mockUSDC)
                )
            })
        );

        vm.stopPrank();
    }

    // ===SwapExactOutput mental model===
    // Exact output:

    // caller owns 10 WETH

    // maxAmountIn = 5.2 WETH
    // amountOut   = 10,000 USDC

    // caller:
    // 10 WETH
    // ↓ pull 5.2

    // adapter:
    // 5.2 WETH
    // ↓ router consumes 4.85

    // router:
    // 4.85 WETH

    // recipient:
    // +10,000 USDC

    // adapter:
    // 0.35 WETH
    // ↓ refund

    // caller:
    // 5.15 WETH remaining total
    function test_swapExactOutput_singleHop() public {
        uint256 deadline = block.timestamp + 30 minutes;
        uint256 amountOut = 10_000e6;
        uint256 routerAmountIn = 4.85 ether;
        router.setExactOutputBehavior(routerAmountIn, routerAmountIn);

        uint24 fee = 3000;
        uint256 maxAmountIn = 5.2 ether;

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), maxAmountIn);

        uint256 amountIn = adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountOut: amountOut,
                maxAmountIn: maxAmountIn,
                recipient: user,
                deadline: deadline,
                route: abi.encode(fee)
            })
        );

        vm.stopPrank();

        assertEq(amountIn, routerAmountIn);
        assertEq(mockUSDC.balanceOf(user), amountOut);
        assertEq(mockWETH.balanceOf(user), initialETHBalance - routerAmountIn);
        assertEq(mockWETH.balanceOf(address(router)), routerAmountIn);

        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);

        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);

        assertEq(router.lastTokenIn(), address(mockWETH));
        assertEq(router.lastTokenOut(), address(mockUSDC));
        assertEq(router.lastFee(), 3000);
        assertEq(router.lastRecipient(), user);
        assertEq(router.lastAmountOut(), amountOut);
        assertEq(router.lastAmountInMaximum(), maxAmountIn);

        // Balance transitions
        // User initially:
        // 10 WETH

        // Adapter pulls max:
        // User     = 4.8
        // Adapter  = 5.2

        // Router spends actual 4.85:
        // Adapter  = 0.35
        // Router   = 4.85

        // Adapter refunds 0.35:
        // Adapter  = 0
        // User     = 5.15

        // => 10 - 5.15 = 4.85 WETH actual expenditure
    }

    function test_swapExactOutput_singleHop_noRefund() public {
        uint256 deadline = block.timestamp + 30 minutes;
        uint256 amountOut = 10_000e6;
        uint256 routerAmountIn = 5 ether;
        router.setExactOutputBehavior(routerAmountIn, routerAmountIn);

        uint24 fee = 3000;
        uint256 maxAmountIn = 5 ether;

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), maxAmountIn);

        uint256 amountIn = adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountOut: amountOut,
                maxAmountIn: maxAmountIn,
                recipient: user,
                deadline: deadline,
                route: abi.encode(fee)
            })
        );

        vm.stopPrank();

        assertEq(amountIn, routerAmountIn);
        assertEq(mockUSDC.balanceOf(user), amountOut);
        assertEq(mockWETH.balanceOf(user), initialETHBalance - routerAmountIn);
        assertEq(mockWETH.balanceOf(address(router)), routerAmountIn);

        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);

        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);

        assertEq(router.lastTokenIn(), address(mockWETH));
        assertEq(router.lastTokenOut(), address(mockUSDC));
        assertEq(router.lastFee(), 3000);
        assertEq(router.lastRecipient(), user);
        assertEq(router.lastAmountOut(), amountOut);
        assertEq(router.lastAmountInMaximum(), maxAmountIn);
    }

    function test_swapExactOutput_singleHop_reverts_whenExcessiveAmountIn() public {
        uint256 amountOut = 10_000e6;
        uint256 maxAmountIn = 5 ether;

        router.setExactOutputBehavior(
            5 ether, // actually spent
            5.1 ether // maliciously reported
        );

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), maxAmountIn);

        vm.expectRevert(abi.encodeWithSelector(UniswapV3SwapAdapter.ExcessiveAmountIn.selector, maxAmountIn, 5.1 ether));

        adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountOut: amountOut,
                maxAmountIn: maxAmountIn,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();

        assertEq(mockWETH.balanceOf(user), initialETHBalance);
        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockWETH.balanceOf(address(router)), 0);
        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);
    }

    function test_swapExactOutput_singleHop_reverts_whenRouterRevert() public {
        uint256 amountOut = 10_000e6;
        uint256 routerAmountIn = 5.1 ether;
        router.setExactOutputBehavior(routerAmountIn, routerAmountIn);
        router.setShouldRevert(true);

        uint256 maxAmountIn = 5 ether;

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), routerAmountIn);

        vm.expectRevert(MockUniswapV3SwapRouter.MockRouterRevert.selector);

        adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountOut: amountOut,
                maxAmountIn: maxAmountIn,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);
        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);
    }

    function test_swapExactOutput_singleHop_reverts_whenTokenInZeroAddress() public {
        uint256 amountOut = 10_000e6;
        uint256 routerAmountIn = 5 ether;
        router.setExactOutputBehavior(routerAmountIn, routerAmountIn);
        router.setShouldRevert(true);

        uint256 maxAmountIn = 5 ether;

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), routerAmountIn);

        vm.expectRevert(UniswapV3SwapAdapter.ZeroAddress.selector);

        adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(0),
                tokenOut: address(mockUSDC),
                amountOut: amountOut,
                maxAmountIn: maxAmountIn,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);
        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);
    }

    function test_swapExactOutput_singleHop_reverts_whenTokenOutZeroAddress() public {
        uint256 amountOut = 10_000e6;
        uint256 routerAmountIn = 5 ether;
        router.setExactOutputBehavior(routerAmountIn, routerAmountIn);
        router.setShouldRevert(true);

        uint256 maxAmountIn = 5 ether;

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), routerAmountIn);

        vm.expectRevert(UniswapV3SwapAdapter.ZeroAddress.selector);

        adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(0),
                amountOut: amountOut,
                maxAmountIn: maxAmountIn,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);
        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);
    }

    function test_swapExactOutput_singleHop_reverts_whenRecipientZeroAddress() public {
        uint256 amountOut = 10_000e6;
        uint256 routerAmountIn = 5 ether;
        router.setExactOutputBehavior(routerAmountIn, routerAmountIn);
        router.setShouldRevert(true);

        uint256 maxAmountIn = 5 ether;

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), routerAmountIn);

        vm.expectRevert(UniswapV3SwapAdapter.ZeroAddress.selector);

        adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountOut: amountOut,
                maxAmountIn: maxAmountIn,
                recipient: address(0),
                deadline: block.timestamp + 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);
        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);
    }

    function test_swapExactOutput_singleHop_reverts_whenZeroAmountOut() public {
        uint256 amountOut = 10_000e6;
        uint256 routerAmountIn = 5 ether;
        router.setExactOutputBehavior(routerAmountIn, routerAmountIn);
        router.setShouldRevert(true);

        uint256 maxAmountIn = 5 ether;

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), routerAmountIn);

        vm.expectRevert(UniswapV3SwapAdapter.ZeroAmountOut.selector);

        adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountOut: 0,
                maxAmountIn: maxAmountIn,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);
        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);
    }

    function test_swapExactOutput_singleHop_reverts_whenSameToken() public {
        uint256 amountOut = 10_000e6;
        uint256 routerAmountIn = 5 ether;
        router.setExactOutputBehavior(routerAmountIn, routerAmountIn);
        router.setShouldRevert(true);

        uint256 maxAmountIn = 5 ether;

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), routerAmountIn);

        vm.expectRevert(UniswapV3SwapAdapter.SameToken.selector);

        adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockWETH),
                amountOut: amountOut,
                maxAmountIn: maxAmountIn,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);
        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);
    }

    function test_swapExactOutput_singleHop_reverts_whenZeroMaxAmountIn() public {
        uint256 amountOut = 10_000e6;
        uint256 routerAmountIn = 5 ether;
        router.setExactOutputBehavior(routerAmountIn, routerAmountIn);
        router.setShouldRevert(true);

        uint256 maxAmountIn = 5 ether;

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), routerAmountIn);

        vm.expectRevert(UniswapV3SwapAdapter.ZeroMaxAmountIn.selector);

        adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountOut: amountOut,
                maxAmountIn: 0,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);
        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);
    }

    function test_swapExactOutput_singleHop_reverts_whenExpiredSwap() public {
        skip(1 days);
        uint256 amountOut = 10_000e6;
        uint256 routerAmountIn = 5 ether;
        router.setExactOutputBehavior(routerAmountIn, routerAmountIn);
        router.setShouldRevert(true);

        uint256 maxAmountIn = 5 ether;

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), routerAmountIn);

        vm.expectRevert(UniswapV3SwapAdapter.ExpiredSwap.selector);

        adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountOut: amountOut,
                maxAmountIn: maxAmountIn,
                recipient: user,
                deadline: block.timestamp - 30 minutes,
                route: abi.encode(uint24(3000))
            })
        );

        vm.stopPrank();

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);
        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);
    }

    function test_swapExactOutput_singleHop_reverts_whenInvalidRoute() public {
        uint256 amountOut = 10_000e6;
        uint256 routerAmountIn = 5 ether;
        router.setExactOutputBehavior(routerAmountIn, routerAmountIn);
        router.setShouldRevert(true);

        uint256 maxAmountIn = 5 ether;
        bytes memory invalidRoute = "0";

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), routerAmountIn);

        vm.expectRevert(UniswapV3SwapAdapter.InvalidRoute.selector);

        adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockUSDC),
                amountOut: amountOut,
                maxAmountIn: maxAmountIn,
                recipient: user,
                deadline: block.timestamp,
                route: invalidRoute
            })
        );

        vm.stopPrank();

        assertEq(mockUSDC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockUSDC.balanceOf(address(adapter)), 0);
        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);
    }

    //=========SwapExactOutput=========
    // Economic route:
    // WETH → USDC → WBTC

    // want exactly:
    // 0.1 WBTC

    // max input:
    // 1.7 WETH

    // router actually spends:
    // 1.55 WETH

    // refund:
    // 0.15 WETH

    function test_swapExactOutput_multihopPath() public {
        uint256 amountOut = 0.1e8; // WBTC
        uint256 maxAmountIn = 1.7 ether; // WETH

        bytes memory route =
            abi.encodePacked(address(mockWBTC), uint24(500), address(mockUSDC), uint24(3000), address(mockWETH));

        router.setExactOutputBehavior(1.55 ether, 1.55 ether);
        router.setMultihopTokens(address(mockWETH), address(mockWBTC));

        assertEq(mockWBTC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), maxAmountIn);

        uint256 amountIn = adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockWBTC),
                amountOut: 0.1e8,
                maxAmountIn: 1.7 ether,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: route
            })
        );

        vm.stopPrank();

        // Happy-path invariants

        // amountIn returned = 1.55 WETH

        // user WETH:
        // 10 - 1.55 = 8.45 WETH

        // user WBTC:
        // +0.1 WBTC

        // router WETH:
        // +1.55 WETH

        // adapter WETH:
        // 0

        // adapter WBTC:
        // 0

        // adapter → router allowance:
        // 0

        assertEq(amountIn, 1.55 ether);
        assertEq(mockWBTC.balanceOf(user), amountOut);
        assertEq(mockWETH.balanceOf(user), initialETHBalance - 1.55 ether);
        assertEq(mockWETH.balanceOf(address(router)), 1.55 ether);

        assertEq(mockWETH.balanceOf(address(adapter)), 0);
        assertEq(mockWBTC.balanceOf(address(adapter)), 0);

        assertEq(mockWETH.allowance(address(adapter), address(router)), 0);

        assertEq(router.lastRecipient(), user);
        assertEq(router.lastAmountOut(), amountOut);
        assertEq(router.lastAmountInMaximum(), maxAmountIn);
    }

    function test_swapExactOutput_multihopPath_reverts_whenTokenMismatch() public {
        router.setExactOutputBehavior(1.55 ether, 1.55 ether);
        router.setMultihopTokens(address(mockWETH), address(mockWBTC));

        assertEq(mockWBTC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1.7 ether);

        vm.expectRevert(UniswapV3SwapAdapter.TokenMismatch.selector);

        uint256 amountIn = adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockUSDC),
                tokenOut: address(mockWBTC),
                amountOut: 0.1e8,
                maxAmountIn: 1.7 ether,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encodePacked(
                    address(mockWBTC), uint24(500), address(mockUSDC), uint24(3000), address(mockWETH)
                )
            })
        );

        vm.stopPrank();

        assertEq(mockWBTC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
    }

    function test_swapExactOutput_multihopPath_reverts_whenInvalidRoute() public {
        router.setExactOutputBehavior(1.55 ether, 1.55 ether);
        router.setMultihopTokens(address(mockWETH), address(mockWBTC));

        assertEq(mockWBTC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1.7 ether);

        vm.expectRevert(UniswapV3SwapAdapter.InvalidRoute.selector);

        uint256 amountIn = adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockWBTC),
                amountOut: 0.1e8,
                maxAmountIn: 1.7 ether,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encodePacked(
                    address(mockWBTC), uint24(500), address(mockUSDC), uint32(3000), address(mockWETH)
                )
            })
        );

        vm.stopPrank();

        assertEq(mockWBTC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
    }

    function test_swapExactOutput_multihopPath_reverts_whenRouterRevert() public {
        router.setExactOutputBehavior(1.55 ether, 1.55 ether);
        router.setMultihopTokens(address(mockWETH), address(mockWBTC));
        router.setShouldRevert(true);

        assertEq(mockWBTC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1.7 ether);

        vm.expectRevert(MockUniswapV3SwapRouter.MockRouterRevert.selector);

        uint256 amountIn = adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockWBTC),
                amountOut: 0.1e8,
                maxAmountIn: 1.7 ether,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encodePacked(
                    address(mockWBTC), uint24(500), address(mockUSDC), uint24(3000), address(mockWETH)
                )
            })
        );

        vm.stopPrank();

        assertEq(mockWBTC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
    }

    function test_swapExactOutput_multihopPath_reverts_whenExcessiveAmountIn() public {
        router.setExactOutputBehavior(1.55 ether, 1.57 ether);
        router.setMultihopTokens(address(mockWETH), address(mockWBTC));

        assertEq(mockWBTC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);

        vm.startPrank(user);
        mockWETH.approve(address(adapter), 1.55 ether);

        vm.expectRevert(abi.encodeWithSelector(UniswapV3SwapAdapter.ExcessiveAmountIn.selector, 1.55 ether, 1.57 ether));

        uint256 amountIn = adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(mockWETH),
                tokenOut: address(mockWBTC),
                amountOut: 0.1e8,
                maxAmountIn: 1.55 ether,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: abi.encodePacked(
                    address(mockWBTC), uint24(500), address(mockUSDC), uint24(3000), address(mockWETH)
                )
            })
        );

        vm.stopPrank();

        assertEq(mockWBTC.balanceOf(user), 0);
        assertEq(mockWETH.balanceOf(user), initialETHBalance);
    }
}
