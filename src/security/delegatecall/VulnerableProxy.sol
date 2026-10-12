// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract VulnerableProxy {
    address public owner; // slot 0
    address public implementation; // slot 1

    constructor(address implementation_) {
        owner = msg.sender;
        implementation = implementation_;
    }

    function upgradeTo(address newImplementation) external {
        require(msg.sender == owner);
        implementation = newImplementation;
    }

    fallback() external payable {
        (bool success, bytes memory returndata) = implementation.delegatecall(msg.data);

        assembly {
            if iszero(success) {
                revert(add(returndata, 0x20), mload(returndata))
            }

            return(add(returndata, 0x20), mload(returndata))
        }
    }
}
