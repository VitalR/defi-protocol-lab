// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IUniswapV3SwapRouter } from "src/labs/swaps/interfaces/IUniswapV3SwapRouter.sol";

contract MockUniswapV3SwapRouter is IUniswapV3SwapRouter {
    using SafeERC20 for IERC20;

    error MockRouterRevert();

    address public lastTokenIn;
    address public lastTokenOut;
    uint24 public lastFee;
    address public lastRecipient;
    uint256 public lastAmountIn;
    uint256 public lastAmountOutMinimum;
    uint256 public amountOut;
    bool public shouldRevert;

    address public multihopTokenIn;
    address public multihopTokenOut;
    bytes public lastPath;

    function setAmountOut(uint256 _amountOut) external {
        amountOut = _amountOut;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function setMultihopTokens(address tokenIn, address tokenOut) external {
        multihopTokenIn = tokenIn;
        multihopTokenOut = tokenOut;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256) {
        if (shouldRevert) revert MockRouterRevert();

        lastPath = params.path;
        lastRecipient = params.recipient;
        lastAmountIn = params.amountIn;
        lastAmountOutMinimum = params.amountOutMinimum;

        IERC20(multihopTokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        IERC20(multihopTokenOut).safeTransfer(params.recipient, amountOut);

        return amountOut;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256) {
        if (shouldRevert) revert MockRouterRevert();

        lastTokenIn = params.tokenIn;
        lastTokenOut = params.tokenOut;
        lastFee = params.fee;
        lastRecipient = params.recipient;
        lastAmountIn = params.amountIn;
        lastAmountOutMinimum = params.amountOutMinimum;

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);

        return amountOut;
    }
}
