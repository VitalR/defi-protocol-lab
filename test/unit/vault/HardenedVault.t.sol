// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { HardenedVault } from "src/vault/HardenedVault.sol";
import { ERC20Mock } from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract HardenedVaultTest is Test {
    HardenedVault public vault;
    ERC20Mock public asset;

    address user = address(0x1001);
    address attacker = address(0x1002);
    address victim = address(0x1003);

    function setUp() public {
        asset = new ERC20Mock();
        vault = new HardenedVault(asset);
    }

    function test_DepositIntoEmptyVaultMintsOneToOneShares() public {
        // Alice deposits 100
        // Expected shares: 100
        // Expected totalSupply: 100
        // Expected totalAssets: 100

        uint256 amount = 100;

        vm.startPrank(user);
        asset.mint(user, amount);
        asset.approve(address(vault), amount);

        uint256 minShares = 100;
        uint256 shares = vault.deposit(amount, minShares);

        vm.stopPrank();

        assertEq(shares, 100);

        uint256 userSharesBalance = vault.balanceOf(user);

        assertEq(userSharesBalance, minShares);
        assertEq(vault.totalAssets(), amount);
        assertEq(vault.totalSupply(), minShares);
    }

    function test_WithdrawRoundsRequiredSharesUp() public {
        // Alice deposits 100 → 100 shares
        // Someone donates 100
        // totalAssets = 200
        // totalSupply = 100

        uint256 amount = 100;
        vm.startPrank(user);
        asset.mint(user, amount);
        asset.approve(address(vault), amount);
        vault.deposit(amount, amount);
        vm.stopPrank();

        assertEq(vault.totalAssets(), amount);
        assertEq(vault.totalSupply(), amount);

        vm.startPrank(attacker);
        asset.mint(attacker, amount);
        // asset.approve(address(vault), amount); // approval is unnecessary for a direct donation
        asset.transfer(address(vault), amount);
        vm.stopPrank();

        vm.prank(user);
        uint256 burnedShares = vault.withdraw(1, 1);

        assertEq(burnedShares, 1);
        assertEq(vault.balanceOf(user), 99);
        assertEq(asset.balanceOf(user), 1);
        // This directly proves that a user cannot withdraw assets while burning zero shares.
    }

    // Important nuance: virtual liquidity makes the attack unprofitable, but VIRTUAL_SHARES = 1 does not fully protect
    // the victim from griefing. The attacker loses assets, but the victim may still receive an unfavorable exchange
    // rate. A larger decimals offset provides stronger protection.
    function test_DonationInflationAttackIsUnprofitable() public {
        // Attacker deposits 1
        // Attacker donates 100
        // Victim deposits 100
        // Attacker redeems their 1 share

        uint256 donation = 100;
        uint256 attackerSpent = donation + 1;

        vm.startPrank(attacker);
        asset.mint(attacker, attackerSpent);
        asset.approve(address(vault), 1);
        vault.deposit(1, 1);
        asset.transfer(address(vault), donation);
        vm.stopPrank();

        vm.startPrank(victim);
        asset.mint(victim, 100);
        asset.approve(address(vault), 100);
        uint256 victimShares = vault.deposit(100, 1);
        vm.stopPrank();

        vm.prank(attacker);
        uint256 attackerReceived = vault.redeem(1, 1);

        assertEq(victimShares, 1);
        assertEq(asset.balanceOf(attacker), 67);
        assertLt(attackerReceived, attackerSpent);
    }
}
