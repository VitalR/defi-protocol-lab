// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ERC20NoReturnMock, ERC20 } from "@openzeppelin/contracts/mocks/token/ERC20NoReturnMock.sol";

contract MockNoReturnERC20 is ERC20NoReturnMock {
    constructor() ERC20("MockNoReturnERC20", "E20M") { }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}
