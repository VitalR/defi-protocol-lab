// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract VulnerablePaymentProcessor {
    mapping(address => uint256) public credits;

    constructor() payable { }

    function setCredit(address user, uint256 amount) external {
        credits[user] = amount;
    }

    function claim() external {
        uint256 amount = credits[msg.sender];

        credits[msg.sender] = 0;

        // BUG:
        // failure does not revert this function
        (bool success,) = payable(msg.sender).call{ value: amount }("");

        // success ignored
    }
}
