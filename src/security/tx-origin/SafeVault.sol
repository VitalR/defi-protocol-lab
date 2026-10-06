// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract SafeVault {
    error Unauthorized();

    address public immutable owner;

    constructor(address owner_) payable {
        owner = owner_;
    }

    function withdraw(address payable recipient) external {
        if (msg.sender != owner) {
            revert Unauthorized();
        }

        recipient.transfer(address(this).balance);
    }
}
