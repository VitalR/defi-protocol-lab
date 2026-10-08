// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { VulnerablePaymentProcessor } from "src/security/unchecked-call/VulnerablePaymentProcessor.sol";
import { SafePaymentProcessor } from "src/security/unchecked-call/SafePaymentProcessor.sol";
import { RejectEther } from "src/security/unchecked-call/RejectEther.sol";

// 1. Low-level calls do not automatically propagate failure.

// 2. Always decide explicitly what failure means.

// 3. EVM call success does not necessarily mean
//    application-level success.

// 4. Preserve CEI:
//    state effects before external interactions,
//    then revert/handle if the interaction fails.

contract UncheckedCallTest is Test {
    VulnerablePaymentProcessor vulnerableProcessor;
    SafePaymentProcessor safeProcessor;
    RejectEther rejectEther;
    address alice;

    function setUp() public {
        vulnerableProcessor = new VulnerablePaymentProcessor{ value: 1 ether }();
        safeProcessor = new SafePaymentProcessor{ value: 1 ether }();
        rejectEther = new RejectEther(vulnerableProcessor);

        alice = makeAddr("alice");
        vm.deal(alice, 1 ether);
    }

    function test_claimSucceedsForEOA() public {
        vulnerableProcessor.setCredit(alice, 1 ether);

        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        vulnerableProcessor.claim();

        assertEq(vulnerableProcessor.credits(alice), 0);

        assertEq(alice.balance, aliceBefore + 1 ether);
    }

    // This is the vulnerability:

    // credit before = 1 ETH

    // claim()
    //     ↓

    // external payment fails

    // but:

    // credit after = 0
    // recipient ETH = 0
    function test_failedExternalCallIsIgnored() public {
        // register 1 ETH credit for RejectEther
        vulnerableProcessor.setCredit(address(rejectEther), 1 ether);

        assertEq(vulnerableProcessor.credits(address(rejectEther)), 1 ether);

        uint256 rejectEtherBefore = address(rejectEther).balance;
        assertEq(address(rejectEther).balance, 0);

        vm.recordLogs();
        // RejectEther calls claim()
        rejectEther.claim();

        // claim itself DOES NOT revert
        assertEq(vm.getRecordedLogs().length, 0);

        // but ETH was not transferred
        assertEq(address(rejectEther).balance, 0);

        // nevertheless credit was erased
        assertEq(vulnerableProcessor.credits(address(rejectEther)), 0 ether);
    }

    function test_safeProcessorRevertsOnFailedCall() public {
        rejectEther.updateProcessor(address(safeProcessor));

        safeProcessor.setCredit(address(rejectEther), 1 ether);

        assertEq(safeProcessor.credits(address(rejectEther)), 1 ether);

        uint256 rejectEtherBefore = address(rejectEther).balance;
        assertEq(address(rejectEther).balance, 0);

        vm.expectRevert(SafePaymentProcessor.TransferFailed.selector);
        rejectEther.claim();

        assertEq(address(rejectEther).balance, 0);

        // safeProcessorPreservesCreditOnFailure
        assertEq(safeProcessor.credits(address(rejectEther)), 1 ether);
    }

    function test_lowLevelCallToEOACanReturnSuccess() public {
        address someEOA = alice;

        (bool success,) = someEOA.call(abi.encodeWithSignature("doesNotExist()"));

        assertTrue(success);
    }
}
