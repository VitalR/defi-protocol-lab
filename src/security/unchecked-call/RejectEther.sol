// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { VulnerablePaymentProcessor } from "src/security/unchecked-call/VulnerablePaymentProcessor.sol";

contract RejectEther {
    VulnerablePaymentProcessor public processor;

    constructor(VulnerablePaymentProcessor processor_) {
        processor = processor_;
    }

    receive() external payable {
        revert();
    }

    function claim() external {
        processor.claim();
    }

    function updateProcessor(address processor_) external {
        processor = VulnerablePaymentProcessor(processor_);
    }
}
