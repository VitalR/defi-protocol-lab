// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

contract SafeProxy {
    bytes32 internal constant IMPLEMENTATION_SLOT = keccak256("security.lab.implementation");

    address public owner;

    constructor(address implementation_) {
        owner = msg.sender;
        _setImplementation(implementation_);
    }

    fallback() external payable {
        (bool success, bytes memory returndata) = implementation().delegatecall(msg.data);

        assembly {
            if iszero(success) {
                revert(add(returndata, 0x20), mload(returndata))
            }

            return(add(returndata, 0x20), mload(returndata))
        }
    }

    function _setImplementation(address implementation_) internal {
        bytes32 slot = IMPLEMENTATION_SLOT;

        assembly {
            sstore(slot, implementation_)
        }
    }

    function implementation() public view returns (address impl) {
        bytes32 slot = IMPLEMENTATION_SLOT;

        assembly {
            impl := sload(slot)
        }
    }
}
