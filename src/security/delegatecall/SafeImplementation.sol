// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract SafeImplementation {
    address public owner;

    function setOwner(address newOwner) external {
        owner = newOwner;
    }
}
