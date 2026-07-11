// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IUniswapV3RouterExactInputSingle (Uniswap V3)
/// @notice Interface for the Uniswap V3 router's exactInputSingle function.
/// @dev This interface is used to interact with the Uniswap V3 router's exactInputSingle function.
interface IUniswapV3RouterExactInputSingle {
    /// @notice Parameters for the exactInputSingle function.
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Executes a single exact input swap.
    /// @param params The parameters for the swap.
    /// @return amountOut The amount of output tokens received.
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
