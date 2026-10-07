// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract VulnerableGame {
    error InvalidDeposit();
    error TargetReached();
    error TargetNotReached();

    uint256 public constant TARGET = 10 ether;
    uint256 public constant DEPOSIT = 1 ether;

    receive() external payable {
        revert();
    }

    function deposit() external payable {
        if (msg.value != DEPOSIT) {
            revert InvalidDeposit();
        }

        if (address(this).balance > TARGET) {
            revert TargetReached();
        }
    }

    function targetReached() external view returns (bool) {
        return address(this).balance == TARGET;
    }
}
