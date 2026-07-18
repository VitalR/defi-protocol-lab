// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract MockZeroFirstERC20 is ERC20Mock {
    error ApprovalMustBeResetToZero(
        address owner, address spender, uint256 currentAllowance, uint256 requestedAllowance
    );

    function approve(address spender, uint256 value) public override returns (bool) {
        uint256 currentAllowance = allowance(msg.sender, spender);

        if (currentAllowance != 0 && value != 0) {
            revert ApprovalMustBeResetToZero(msg.sender, spender, currentAllowance, value);
        }

        return super.approve(spender, value);
    }
}
