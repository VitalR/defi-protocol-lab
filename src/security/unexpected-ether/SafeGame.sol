// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract SafeGame {
    error InvalidDeposit();
    error TargetReached();

    uint256 public constant TARGET = 10 ether;
    uint256 public constant DEPOSIT = 1 ether;

    uint256 public accountedDeposits;

    function deposit() external payable {
        if (msg.value != DEPOSIT) {
            revert InvalidDeposit();
        }

        uint256 nextDeposits = accountedDeposits + msg.value;

        if (nextDeposits > TARGET) {
            revert TargetReached();
        }

        accountedDeposits = nextDeposits;
    }

    function targetReached() external view returns (bool) {
        return accountedDeposits == TARGET;
    }
}
