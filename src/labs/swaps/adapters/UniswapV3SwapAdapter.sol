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
    error SameToken();
    error ExpiredSwap();
    error InvalidRoute();
    error InsufficientAmountOut(uint256 minimum, uint256 actual);
    error TokenMismatch();

    address public immutable router;

    constructor(address _router) {
        require(_router != address(0) && _router.code.length != 0, InvalidRouter());
        router = _router;
    }

    function swapExactInput(ExactInputParams calldata params) external returns (uint256 receivedAmount) {
        _validateExactInputParams(params);

        bool isSingleHop = params.route.length == 32;

        if (!isSingleHop) {
            _validateMultihopPath(params.route);

            address tokenIn = _decodeFirstToken(params.route);
            address tokenOut = _decodeLastToken(params.route);

            require(tokenIn == params.tokenIn && tokenOut == params.tokenOut, TokenMismatch());
        }

        IERC20 tokenIn = IERC20(params.tokenIn);

        TokenTransfer.pullExact(tokenIn, msg.sender, params.amountIn);
        tokenIn.forceApprove(router, params.amountIn);

        if (isSingleHop) {
            uint24 fee = abi.decode(params.route, (uint24));

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
        } else {
            receivedAmount = IUniswapV3SwapRouter(router)
                .exactInput(
                    IUniswapV3SwapRouter.ExactInputParams({
                        path: params.route,
                        recipient: params.recipient,
                        deadline: params.deadline,
                        amountIn: params.amountIn,
                        amountOutMinimum: params.minAmountOut
                    })
                );
        }

        tokenIn.forceApprove(router, 0);

        if (receivedAmount < params.minAmountOut) {
            revert InsufficientAmountOut(params.minAmountOut, receivedAmount);
        }
    }

    function _validateExactInputParams(ExactInputParams calldata params) internal view {
        require(
            params.tokenIn != address(0) && params.tokenOut != address(0) && params.recipient != address(0),
            ZeroAddress()
        );
        require(params.tokenIn != params.tokenOut, SameToken());
        require(params.amountIn > 0, ZeroAmountIn());
        require(params.minAmountOut > 0, ZeroMinAmountOut());
        require(params.deadline >= block.timestamp, ExpiredSwap());
    }

    function _validateMultihopPath(bytes calldata path) internal pure {
        require(path.length >= 66, InvalidRoute());

        // For V3 path:
        // token + (fee + token) * N
        // 20 + N * (3 + 20) = 20 + N * 23

        // 2 hops: 20 + 2 * 23 = 66
        // 3 hops: 20 + 3 * 23 = 89
        require((path.length - 20) % 23 == 0, InvalidRoute());
    }

    function _decodeFirstToken(bytes calldata path) internal pure returns (address tokenIn) {
        // Why shr(96, ...)?
        // calldataload reads 32 bytes:
        // [20 bytes address][12 bytes following data]
        // Shift right by 12 bytes (96 bits) to keep the leading 20-byte address.
        assembly {
            tokenIn := shr(96, calldataload(path.offset))
        }
    }

    function _decodeLastToken(bytes calldata path) internal pure returns (address tokenOut) {
        assembly {
            tokenOut := shr(96, calldataload(add(path.offset, sub(path.length, 20))))
        }
    }
}
