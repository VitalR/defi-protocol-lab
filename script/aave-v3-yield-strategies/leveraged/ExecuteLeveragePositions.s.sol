// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { LeveragePositionManager } from "src/aave-v3-yield-strategies/leveraged/LeveragePositionManager.sol";
import { AaveV3Sepolia, AaveV3SepoliaAssets } from "src/aave-v3-yield-strategies/libs/AaveV3Sepolia.sol";
import { TokenActions } from "src/aave-v3-yield-strategies/libs/TokenActions.sol";

/// @title ExecuteLeveragePositions (ops/demo for LeveragePositionManager)
/// @notice Small runner script to open/close positions using LeveragePositionManager on Sepolia.
/// @dev Avoids param/function name shadowing; calls `_aTokenOf` correctly.
contract ExecuteLeveragePositions is Script {
    using TokenActions for IERC20;

    // --- Wire addresses (Sepolia) ---
    // Aave Pool / Data are passed to the manager when you deploy it.
    // Here we assume LeveragePositionManager is already deployed; set via env STRAT_LEVERAGE or DevOpsTools.
    // Uniswap V3 router on Sepolia (popular deployment):
    address constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564; // change if your router differs

    // Example assets (Aave Sepolia)
    function collToken() internal pure returns (address) {
        // e.g., WBTC as collateral (8 decimals)
        return AaveV3SepoliaAssets.WBTC_UNDERLYING;
    }

    function debtToken() internal pure returns (address) {
        // e.g., USDC as debt (6 decimals)
        return AaveV3SepoliaAssets.USDC_UNDERLYING;
    }

    // --- Dispatcher ---
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        // Example calls (comment/uncomment as needed):
        // openLongExample();
        // closePositionExample();

        vm.stopBroadcast();
    }

    // --- Examples ---

    /// @notice Example: open a “leveraged long” WBTC using borrowed USDC -> swap to WBTC and (optionally) resupply.
    function openLongExample() public {
        LeveragePositionManager mgr = LeveragePositionManager(_resolveManager());

        LeveragePositionManager.OpenParams memory p = LeveragePositionManager.OpenParams({
            collateralToken: collToken(),
            collateralAmount: 1e8, // 1 WBTC (8 decimals)
            borrowToken: debtToken(),
            borrowAmount: 5000e6, // 5,000 USDC (6 decimals)
            referralCode: 0, // Aave referral (0 if unused)
            uniFee: 3000, // 0.3% pool
            minOut: 0, // demo only; set slippage guard in real runs
            deadline: block.timestamp + 1800,
            minHealthFactor: 12e17, // >=1.2
            resupplySwapped: true // re-supply swapped WBTC back to user’s Aave position
         });

        // Make sure this EOA has enough collateral & debt token approvals if needed by your flow
        // For demo, we assume wallet already holds the collateral and will receive borrowed tokens to then be swapped.
        // If you want manager to *pull* the borrowed tokens from user for swap, user must have allowance set to this
        // script or manager,
        // in our open() we pull debt from user *after* borrowing (non-custodial).

        // Approve manager to pull collateral
        IERC20(p.collateralToken).approveExact(address(mgr), p.collateralAmount);

        uint256 out = mgr.open(p);
        console2.log("open() swapped-to-collateral:", out);

        // Show user’s aToken balance for collateral
        address aTok = mgr._aTokenOf(p.collateralToken);
        uint256 aBal = IERC20(aTok).balanceOf(msg.sender);
        console2.log("user aToken balance (coll):", aBal);
    }

    /// @notice Example: close part/all of position — withdraw collateral, swap to USDC, repay variable debt, return
    /// leftovers.
    function closePositionExample() public {
        LeveragePositionManager mgr = LeveragePositionManager(_resolveManager());

        // Pull all aTokens, withdraw all collateral, swap to debt token, repay as much as needed (0 => all)
        LeveragePositionManager.CloseParams memory p = LeveragePositionManager.CloseParams({
            collateralToken: collToken(),
            borrowToken: debtToken(),
            aTokensToPull: type(uint256).max, // pull all user aTokens
            withdrawAmount: type(uint256).max, // withdraw all underlying
            uniFee: 3000,
            minOut: 0, // demo only
            deadline: block.timestamp + 1800,
            maxDebtToRepay: 0 // repay full current variable debt
         });

        // Approve manager to pull aTokens from user
        address aTok = mgr._aTokenOf(p.collateralToken);
        uint256 aBal = IERC20(aTok).balanceOf(msg.sender);
        IERC20(aTok).approveExact(address(mgr), aBal);

        (uint256 withdrawn, uint256 fromUser, uint256 leftoverDebt) = mgr.close(p);
        console2.log("close() withdrawn coll :", withdrawn);
        console2.log("close() extra repay    :", fromUser);
        console2.log("close() leftover debtT :", leftoverDebt);
    }

    // --- Resolve manager address (env or revert) ---
    function _resolveManager() internal view returns (address addr) {
        // Expect STRAT_LEVERAGE in env
        try vm.envAddress("STRAT_LEVERAGE") returns (address a) {
            addr = a;
        } catch {
            revert("set STRAT_LEVERAGE env to LeveragePositionManager address");
        }
        require(addr != address(0), "bad STRAT_LEVERAGE");
    }
}
