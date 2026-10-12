// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract BadImplementation {
    address public owner; // slot 0

    function setOwner(address newOwner) external {
        owner = newOwner;
    }
}

contract BadImplementationV2 {
    uint256 public version; // slot 0
    address public owner; // slot 1

    function setOwner(address newOwner) external {
        owner = newOwner;
    }
}

contract ContextImplementation {
    function context() external view returns (address current, address sender) {
        return (address(this), msg.sender);
    }
}
