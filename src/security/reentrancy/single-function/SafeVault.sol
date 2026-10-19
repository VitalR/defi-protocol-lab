// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract SafeVault {
    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    // first withdraw
    //     ↓
    // balances[attacker] = 0
    //     ↓
    // external call
    //     ↓
    // attacker re-enters
    //     ↓
    // amount = 0
    function withdraw() external {
        uint256 amount = balances[msg.sender];

        balances[msg.sender] = 0;

        (bool success,) = payable(msg.sender).call{ value: amount }("");

        require(success);
    }
}
