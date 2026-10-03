// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract MockWETH is ERC20Mock {
    function name() public view override returns (string memory) {
        return "MockWETH";
    }

    function symbol() public view override returns (string memory) {
        return "WETH";
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
