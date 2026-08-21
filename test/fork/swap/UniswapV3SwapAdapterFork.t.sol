// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { UniswapV3SwapAdapter, ISwapAdapter } from "src/labs/swaps/adapters/UniswapV3SwapAdapter.sol";

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IWETH is IERC20 {
    function deposit() external payable;
}

contract UniswapV3SwapAdapterForkTest is Test {
    uint256 internal constant FORK_BLOCK = 25_600_000; // block finalized, timestamp 24 July 2026 03:46:47 UTC
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant WETH_USDC_POOL_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    uint24 internal constant WETH_USDC_FEE = 500;

    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant USDC_WBTC_POOL_3000 = 0x99ac8cA7087fA4A2A1FB6357269965A2014ABc35;
    uint24 internal constant USDC_WBTC_FEE = 3000;

    UniswapV3SwapAdapter internal adapter;

    address internal user = address(0x1001);

    function setUp() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);

        adapter = new UniswapV3SwapAdapter(UNISWAP_V3_ROUTER);

        assertGt(WETH.code.length, 0);
        assertGt(USDC.code.length, 0);
        assertGt(UNISWAP_V3_ROUTER.code.length, 0);
        assertGt(WETH_USDC_POOL_500.code.length, 0);
        assertGt(UNISWAP_V3_FACTORY.code.length, 0);
        assertEq(IUniswapV3Factory(UNISWAP_V3_FACTORY).getPool(WETH, USDC, WETH_USDC_FEE), WETH_USDC_POOL_500);
        assertEq(IUniswapV3Factory(UNISWAP_V3_FACTORY).getPool(USDC, WBTC, USDC_WBTC_FEE), USDC_WBTC_POOL_3000);

        vm.deal(user, 10 ether);
        vm.prank(user);
        IWETH(WETH).deposit{ value: 2 ether }();

        assertEq(IWETH(WETH).balanceOf(user), 2 ether);
    }

    function test_forkSetup() public view {
        assertEq(IWETH(WETH).balanceOf(user), 2 ether);

        assertEq(IUniswapV3Factory(UNISWAP_V3_FACTORY).getPool(WETH, USDC, WETH_USDC_FEE), WETH_USDC_POOL_500);
    }

    function test_swapExactInput_singleHop() public {
        uint256 amountIn = 0.01 ether;
        // At FORK_BLOCK, 0.01 WETH yields ~18.78 USDC.
        // Keep a conservative bound instead of asserting the exact quote.
        uint256 minAmountOut = 18_500_000; // 18.5 USDC

        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);

        vm.startPrank(user);

        IERC20(WETH).approve(address(adapter), amountIn);

        uint256 amountOut = adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(WETH),
                tokenOut: address(USDC),
                amountIn: amountIn,
                minAmountOut: minAmountOut,
                recipient: user,
                deadline: block.timestamp + 15 minutes,
                route: abi.encode(WETH_USDC_FEE)
            })
        );

        vm.stopPrank();

        // production-like flow:
        // user
        // │ approve 0.01 WETH
        // ▼
        // UniswapV3SwapAdapter
        // │ pullExact(0.01 WETH)
        // │ approve Router(0.01 WETH)
        // ▼
        // real Uniswap V3 SwapRouter
        // │ exactInputSingle(...)
        // ▼
        // real WETH/USDC 0.05% pool
        // │ USDC → user
        // │
        // └─ callback → Router
        //                 │
        //                 └─ transferFrom(Adapter → Pool, 0.01 WETH)

        // Adapter
        // └─ approve Router = 0

        uint256 wethAfter = IERC20(WETH).balanceOf(user);
        uint256 usdcAfter = IERC20(USDC).balanceOf(user);

        assertEq(wethBefore - wethAfter, amountIn);
        assertEq(usdcAfter - usdcBefore, amountOut);
        assertGe(amountOut, minAmountOut);

        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);

        assertEq(IERC20(WETH).allowance(address(adapter), UNISWAP_V3_ROUTER), 0);
    }

    function test_swapExactInput_multihop() public {
        uint256 amountIn = 0.01 ether;
        // At FORK_BLOCK, 0.01 WETH yields ~0.00028749 WBTC.
        // Keep a conservative bound instead of asserting the exact quote.
        uint256 minAmountOut = 27_000; // 0.00027 WBTC

        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        uint256 wbtcBefore = IERC20(WBTC).balanceOf(user);

        bytes memory route = abi.encodePacked(WETH, uint24(500), USDC, uint24(3000), WBTC);

        vm.startPrank(user);

        IERC20(WETH).approve(address(adapter), amountIn);

        uint256 amountOut = adapter.swapExactInput(
            ISwapAdapter.ExactInputParams({
                tokenIn: address(WETH),
                tokenOut: address(WBTC),
                amountIn: amountIn,
                minAmountOut: minAmountOut,
                recipient: user,
                deadline: block.timestamp + 15 minutes,
                route: route
            })
        );

        vm.stopPrank();

        uint256 wethAfter = IERC20(WETH).balanceOf(user);
        uint256 wbtcAfter = IERC20(WBTC).balanceOf(user);

        assertEq(wethBefore - wethAfter, amountIn);
        assertEq(wbtcAfter - wbtcBefore, amountOut);
        assertGe(amountOut, minAmountOut);

        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(WBTC).balanceOf(address(adapter)), 0);

        assertEq(IERC20(WETH).allowance(address(adapter), UNISWAP_V3_ROUTER), 0);
    }

    function test_swapExactOutput_singleHop() public {
        uint256 amountOut = 10e6; // exactly 10 USDC
        uint256 maxAmountIn = 0.01 ether;

        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);

        vm.startPrank(user);

        IERC20(WETH).approve(address(adapter), maxAmountIn);

        uint256 amountIn = adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(WETH),
                tokenOut: address(USDC),
                amountOut: amountOut,
                maxAmountIn: maxAmountIn,
                recipient: user,
                deadline: block.timestamp + 15 minutes,
                route: abi.encode(WETH_USDC_FEE)
            })
        );

        vm.stopPrank();

        uint256 wethAfter = IERC20(WETH).balanceOf(user);
        uint256 usdcAfter = IERC20(USDC).balanceOf(user);

        // Mental model:
        // WETH delta == actual amountIn
        // USDC delta == exact requested amountOut
        // actual amountIn <= maxAmountIn
        assertEq(wethBefore - wethAfter, amountIn);
        assertEq(usdcAfter - usdcBefore, amountOut);

        assertLt(amountIn, maxAmountIn);

        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);

        assertEq(IERC20(WETH).allowance(address(adapter), UNISWAP_V3_ROUTER), 0);
    }

    function test_swapExactOutput_multihop() public {
        uint256 amountOut = 27_000;
        uint256 maxAmountIn = 0.01 ether;

        bytes memory route = abi.encodePacked(WBTC, uint24(3000), USDC, uint24(500), WETH);

        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        uint256 wbtcBefore = IERC20(WBTC).balanceOf(user);

        vm.startPrank(user);

        IERC20(WETH).approve(address(adapter), maxAmountIn);

        uint256 amountIn = adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(WETH),
                tokenOut: address(WBTC),
                amountOut: amountOut,
                maxAmountIn: maxAmountIn,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: route
            })
        );

        vm.stopPrank();

        uint256 wethAfter = IERC20(WETH).balanceOf(user);
        uint256 wbtcAfter = IERC20(WBTC).balanceOf(user);

        assertEq(wethBefore - wethAfter, amountIn);
        assertEq(wbtcAfter - wbtcBefore, amountOut);

        assertLt(amountIn, maxAmountIn);

        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(WBTC).balanceOf(address(adapter)), 0);

        assertEq(IERC20(WETH).allowance(address(adapter), UNISWAP_V3_ROUTER), 0);
    }

    function test_swapExactOutput_multihop_reverts_tooLowMaxAmountIn() public {
        uint256 amountOut = 27_000;
        uint256 maxAmountIn = 0.003 ether;

        bytes memory route = abi.encodePacked(WBTC, uint24(3000), USDC, uint24(500), WETH);

        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        uint256 wbtcBefore = IERC20(WBTC).balanceOf(user);

        vm.startPrank(user);

        IERC20(WETH).approve(address(adapter), maxAmountIn);

        vm.expectRevert();

        uint256 amountIn = adapter.swapExactOutput(
            ISwapAdapter.ExactOutputParams({
                tokenIn: address(WETH),
                tokenOut: address(WBTC),
                amountOut: amountOut,
                maxAmountIn: maxAmountIn,
                recipient: user,
                deadline: block.timestamp + 30 minutes,
                route: route
            })
        );

        vm.stopPrank();

        uint256 wethAfter = IERC20(WETH).balanceOf(user);
        uint256 wbtcAfter = IERC20(WBTC).balanceOf(user);

        assertEq(wethBefore, wethAfter);
        assertEq(wbtcAfter, wbtcBefore);

        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(WBTC).balanceOf(address(adapter)), 0);

        assertEq(IERC20(WETH).allowance(address(adapter), UNISWAP_V3_ROUTER), 0);
    }
}

//                     ONE EVM TRANSACTION

// User
//  │
//  │ max 0.01 WETH
//  ▼
// Adapter
//  │
//  │ approve Router
//  ▼
// Router
//  │
//  │ exactOutput
//  ▼
// Pool
//  │
//  ├─────────────── 10 USDC ───────────────► User
//  │
//  │ callback:
//  ▼
// Router
//  │
//  │ transferFrom Adapter
//  ▼
// 0.005325 WETH
//  │
//  ▼
// Pool

// Adapter initially pulled:   0.010000 WETH
// Pool actually required:     0.005325 WETH
//                             ──────────────
// Refund to caller:           0.004675 WETH
