// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract VulnerableVault {
    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    // Single-function reentrancy:
    //
    // withdraw()
    // ↓
    // send ETH
    // ↓
    // attacker.receive()
    // ↓
    // withdraw()
    // ↓
    // send ETH
    // ↓
    // attacker.receive()
    // ↓
    // ...
    function withdraw() external {
        uint256 amount = balances[msg.sender];

        (bool success,) = payable(msg.sender).call{ value: amount }("");

        require(success);

        balances[msg.sender] = 0;
    }
}
