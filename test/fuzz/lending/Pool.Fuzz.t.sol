// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Pool } from "src/lending/Pool.sol";
import { PoolAddressProvider } from "src/lending/PoolAddressProvider.sol";
import { PoolConfigurator } from "src/lending/PoolConfigurator.sol";
import { ScaledSupplyToken } from "src/lending/tokens/ScaledSupplyToken.sol";
import { PoolHarness } from "test/helpers/PoolHarness.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";

contract PoolFuzzTest is Test {
    uint256 internal constant WAD = 1e18;

    address internal admin = address(0x1000);
    address internal alice = address(0x1001);

    PoolHarness internal pool;
    PoolAddressProvider internal provider;
    PoolConfigurator internal configurator;
    MockUSDC internal usdc;
    ScaledSupplyToken internal supplyToken;

    function setUp() public {
        provider = new PoolAddressProvider(admin);
        configurator = new PoolConfigurator(admin, address(provider));
        pool = new PoolHarness(address(provider));
        usdc = new MockUSDC();

        vm.startPrank(admin);
        provider.setPool(address(pool));
        provider.setPoolConfigurator(address(configurator));
        configurator.initReserve(address(usdc));
        vm.stopPrank();

        supplyToken = ScaledSupplyToken(pool.getReserveData(address(usdc)).supplyToken);
    }

    /// @notice A round-trip at an unchanged elevated index cannot create underlying profit.
    /// @dev This tests share conversion and rounding, not organic interest accrual.
    function testFuzz_supplyThenFullWithdrawAtRaisedIndex(uint256 amountSeed, uint256 indexSeed) public {
        uint256 amount = bound(amountSeed, 1e6, 1_000_000e6);
        uint256 index = bound(indexSeed, WAD, 3 * WAD);

        // Set the synthetic index before any deposits; no economic yield is manufactured.
        pool.setLiquidityIndexForTest(address(usdc), index);

        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(pool), amount);
        pool.supply(address(usdc), amount, alice);

        uint256 shares = supplyToken.scaledBalanceOf(alice);
        uint256 expectedShares = Math.mulDiv(amount, WAD, index, Math.Rounding.Floor);
        uint256 expectedWithdrawn = Math.mulDiv(expectedShares, index, WAD, Math.Rounding.Floor);

        assertEq(shares, expectedShares, "incorrect shares minted");
        assertGt(shares, 0, "zero shares");
        assertEq(usdc.balanceOf(address(supplyToken)), amount, "custody after supply");
        assertEq(pool.availableLiquidity(address(usdc)), amount, "accounted cash after supply");

        uint256 withdrawn = pool.withdraw(address(usdc), type(uint256).max, alice);
        vm.stopPrank();

        uint256 dust = amount - withdrawn;
        uint256 maxDust = Math.mulDiv(index, 1, WAD, Math.Rounding.Ceil);

        assertEq(withdrawn, expectedWithdrawn, "incorrect full withdrawal");
        assertLe(withdrawn, amount, "round-trip profit");
        assertLe(dust, maxDust, "excessive rounding dust");

        assertEq(supplyToken.scaledBalanceOf(alice), 0, "shares not fully burned");
        assertEq(supplyToken.scaledTotalSupply(), 0, "scaled supply not cleared");
        assertEq(supplyToken.balanceOf(alice), 0, "actual claim not cleared");
        assertEq(usdc.balanceOf(alice), withdrawn, "recipient cash mismatch");
        assertEq(usdc.balanceOf(address(supplyToken)), dust, "custody cash mismatch");
        assertEq(pool.availableLiquidity(address(usdc)), dust, "accounted cash mismatch");
        assertEq(pool.unaccountedCash(address(usdc)), 0, "unexpected unaccounted cash");
    }
}
