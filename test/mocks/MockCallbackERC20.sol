// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ERC20Reentrant } from "@openzeppelin/contracts/mocks/token/ERC20Reentrant.sol";

contract MockCallbackERC20 is ERC20Reentrant {
    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}
