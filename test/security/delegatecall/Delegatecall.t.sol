// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { VulnerableProxy } from "src/security/delegatecall/VulnerableProxy.sol";
import { BadImplementation, ContextImplementation } from "src/security/delegatecall/BadImplementation.sol";
import { SafeProxy } from "src/security/delegatecall/SafeProxy.sol";
import { SafeImplementation } from "src/security/delegatecall/SafeImplementation.sol";

contract DelegatecallTest is Test {
    VulnerableProxy vulnerableProxy;
    BadImplementation badImplementation;

    address alice;
    address bob;
    address attacker;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        attacker = makeAddr("attacker");

        badImplementation = new BadImplementation();

        vm.prank(alice);
        vulnerableProxy = new VulnerableProxy(address(badImplementation));
    }

    function test_delegatecallUsesProxyContext() public {
        ContextImplementation contextImplementation = new ContextImplementation();

        VulnerableProxy proxy = new VulnerableProxy(address(contextImplementation));

        vm.prank(alice);

        // (bool success, bytes memory returndata) =
        //     address(proxy).call(abi.encodeWithSelector(ContextImplementation.context.selector));

        // assertTrue(success);

        // (address current, address sender) = abi.decode(returndata, (address, address));

        // Encode the call using ContextImplementation's ABI and send it to proxy.
        (address current, address sender) = ContextImplementation(address(proxy)).context();

        // ContextImplementation(address(proxy)).context()
        //            ↓
        //       call proxy
        //            ↓
        //      proxy fallback
        //            ↓
        // delegatecall implementation

        assertEq(current, address(proxy));
        assertEq(sender, alice);
    }

    function test_delegatecallCanOverwriteProxyOwner() public {
        assertEq(vulnerableProxy.owner(), alice);

        vm.prank(bob);

        BadImplementation(address(vulnerableProxy)).setOwner(bob);

        assertEq(vulnerableProxy.owner(), bob);
    }

    function test_ownerTakeoverAllowsUpgrade() public { }

    // test_storageLayoutMismatchCorruptsState()

    // test_safeProxyMetadataDoesNotCollide()
}

