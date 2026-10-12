// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { VulnerableProxy } from "src/security/delegatecall/VulnerableProxy.sol";
import {
    BadImplementation,
    BadImplementationV2,
    ContextImplementation
} from "src/security/delegatecall/BadImplementation.sol";
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

    // “Okay, Bob overwrote proxy.owner. So what?”
    // The security consequence is that Bob can now use privileged proxy functions.
    function test_delegatecallCanOverwriteProxyOwner() public {
        assertEq(vulnerableProxy.owner(), alice);

        vm.prank(bob);

        BadImplementation(address(vulnerableProxy)).setOwner(bob);

        assertEq(vulnerableProxy.owner(), bob);
    }

    // storage corruption
    //     ↓
    // privilege takeover
    //     ↓
    // implementation takeover
    function test_ownerTakeoverAllowsUpgrade() public {
        address originalImplementation = vulnerableProxy.implementation();

        BadImplementation maliciousImplementation = new BadImplementation();

        // Bob is not owner yet.
        vm.prank(bob);
        vm.expectRevert();
        vulnerableProxy.upgradeTo(address(maliciousImplementation));

        // Exploit delegated storage write.
        vm.prank(bob);
        BadImplementation(address(vulnerableProxy)).setOwner(bob);

        assertEq(vulnerableProxy.owner(), bob);

        // Bob now has admin power.
        vm.prank(bob);
        vulnerableProxy.upgradeTo(address(maliciousImplementation));

        assertNotEq(vulnerableProxy.implementation(), originalImplementation);

        assertEq(vulnerableProxy.implementation(), address(maliciousImplementation));
    }

    // Even trusted implementation code can become dangerous if a later implementation changes storage layout.
    function test_storageLayoutMismatchCorruptsState() public {
        BadImplementationV2 v2 = new BadImplementationV2();

        vm.prank(alice);
        vulnerableProxy.upgradeTo(address(v2));
        // At this moment:
        // proxy.owner          = alice
        // proxy.implementation = address(v2)

        assertEq(vulnerableProxy.implementation(), address(v2));

        assertEq(vulnerableProxy.owner(), alice);

        vm.prank(bob);

        BadImplementationV2(address(vulnerableProxy)).setOwner(bob);
        // So after the call:
        // proxy.owner          = alice
        // proxy.implementation = bob

        // owner was NOT changed
        assertEq(vulnerableProxy.owner(), alice);

        // slot 1 was overwritten instead
        assertEq(vulnerableProxy.implementation(), bob);
    }

    function test_safeProxyMetadataDoesNotCollide() public {
        SafeImplementation impl = new SafeImplementation();

        SafeProxy proxy = new SafeProxy(address(impl));

        address implementationBefore = proxy.implementation();

        vm.prank(bob);

        SafeImplementation(address(proxy)).setOwner(bob);

        // implementation state changed
        assertEq(SafeImplementation(address(proxy)).owner(), bob);

        // proxy metadata unchanged
        assertEq(proxy.implementation(), implementationBefore);
    }

    // You still need to worry about:
    // implementation-to-implementation layout compatibility
    // authorization
    // initialization
    // upgrade permissions
    // untrusted delegatecall
    // function selector collisions

    // So think of the protections as separate layers:
    // hashed proxy metadata slots
    //     ↓
    // protect proxy admin/implementation metadata

    // stable implementation layout
    //     ↓
    // protect application state across upgrades
}

