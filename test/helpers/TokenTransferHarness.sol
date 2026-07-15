// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { TokenTransfer, IERC20 } from "src/common/token/TokenTransfer.sol";

contract TokenTransferHarness {
    function pullExact(IERC20 token, address from, uint256 amount) external returns (uint256 received) {
        return TokenTransfer.pullExact(token, from, amount);
    }

    function pullBalanceDelta(IERC20 token, address from, uint256 amount) external returns (uint256 received) {
        return TokenTransfer.pullBalanceDelta(token, from, amount);
    }
}
