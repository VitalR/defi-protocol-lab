// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

// SECURITY LAB ONLY:
// selfdestruct is deprecated but used here to demonstrate
// that ETH can be transferred without executing target code.
contract ForceEther {
    constructor() payable { }

    function force(address payable target) external {
        selfdestruct(target);
    }
}
