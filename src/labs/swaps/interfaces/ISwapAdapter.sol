// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface ISwapAdapter {
    struct ExactInputParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient;
        uint256 deadline;
        bytes route;
    }

    function swapExactInput(ExactInputParams calldata params) external returns (uint256 amountOut);
}
