// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract Spender {
    IERC20 public immutable token;

    constructor(IERC20 token_) {
        token = token_;
    }

    function pull(address from, address to, uint256 amount) external {
        token.transferFrom(from, to, amount);
    }
}

