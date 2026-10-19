// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract CrossFunctionVault {
    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];

        (bool success,) = payable(msg.sender).call{ value: amount }("");

        require(success);

        balances[msg.sender] = 0;
    }

    function transferBalance(address to, uint256 amount) external {
        require(balances[msg.sender] >= amount);

        balances[msg.sender] -= amount;
        balances[to] += amount;
    }

    function safeWithdraw() external {
        uint256 amount = balances[msg.sender];

        balances[msg.sender] = 0;

        (bool success,) = payable(msg.sender).call{ value: amount }("");

        require(success);
    }
}
