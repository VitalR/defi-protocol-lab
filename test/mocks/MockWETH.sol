// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract MockWETH is ERC20Mock {
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
