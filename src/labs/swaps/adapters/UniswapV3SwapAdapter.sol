// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwapAdapter } from "src/labs/swaps/interfaces/ISwapAdapter.sol";
import { IUniswapV3SwapRouter } from "src/labs/swaps/interfaces/IUniswapV3SwapRouter.sol";
import { TokenTransfer } from "src/common/token/TokenTransfer.sol";

contract UniswapV3SwapAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    error InvalidRouter();
    error ZeroAddress();
    error ZeroAmountIn();
    error ZeroMinAmountOut();
    error ZeroFee();
    error SameToken();
    error ExpiredSwap();
    error InvalidRoute();
    error InsufficientAmountOut(uint256 minimum, uint256 actual);

    address public immutable router;

    constructor(address _router) {
        require(_router != address(0) && _router.code.length != 0, InvalidRouter());
        router = _router;
    }

    function swapExactInput(ExactInputParams calldata params) external returns (uint256 receivedAmount) {
        require(
            params.tokenIn != address(0) && params.tokenOut != address(0) && params.recipient != address(0),
            ZeroAddress()
        );
        require(params.tokenIn != params.tokenOut, SameToken());
        require(params.amountIn > 0, ZeroAmountIn());
        require(params.minAmountOut > 0, ZeroMinAmountOut());
        require(params.deadline >= block.timestamp, ExpiredSwap());
        require(params.route.length == 32, InvalidRoute());

        uint24 fee = abi.decode(params.route, (uint24));

        TokenTransfer.pullExact(IERC20(params.tokenIn), msg.sender, params.amountIn);

        IERC20(params.tokenIn).forceApprove(router, params.amountIn);

        receivedAmount = IUniswapV3SwapRouter(router)
            .exactInputSingle(
                IUniswapV3SwapRouter.ExactInputSingleParams({
                    tokenIn: params.tokenIn,
                    tokenOut: params.tokenOut,
                    fee: fee,
                    recipient: params.recipient,
                    deadline: params.deadline,
                    amountIn: params.amountIn,
                    amountOutMinimum: params.minAmountOut,
                    sqrtPriceLimitX96: 0
                })
            );

        IERC20(params.tokenIn).forceApprove(router, 0);

        if (receivedAmount < params.minAmountOut) revert InsufficientAmountOut(params.minAmountOut, receivedAmount);
    }
}
