// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract MockUSDC is ERC20Mock {
    function name() public view override returns (string memory) {
        return "MockUSDC";
    }

    function symbol() public view override returns (string memory) {
        return "USDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
