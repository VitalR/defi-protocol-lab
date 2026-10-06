// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract VulnerableVault {
    error NotOwner();

    address public owner;

    constructor(address owner_) payable {
        owner = owner_;
    }

    function withdraw(address payable recipient) external {
        require(tx.origin == owner, NotOwner());

        recipient.transfer(address(this).balance);
    }
}
