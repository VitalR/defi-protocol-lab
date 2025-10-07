// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import { DevOpsTools } from "lib/foundry-devops/src/DevOpsTools.sol";
import { FlashLoanExecutor } from "../../src/aave-v3-yield-strategies/FlashLoanExecutor.sol";
import { AaveV3Sepolia } from "../../src/aave-v3-yield-strategies/libs/AaveV3Sepolia.sol";
import { EnvUtils } from "../utils/EnvUtils.s.sol";

/// @notice Drives a flash loan on Sepolia. If TARGET+DATA are omitted, it performs a no-op.
contract ExecuteFlashLoanScript is Script, EnvUtils {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        // (1) Resolve / deploy executor
        address executor;
        try vm.envAddress("FLASH_EXECUTOR") returns (address e) {
            executor = e;
        } catch {
            executor = address(new FlashLoanExecutor(AaveV3Sepolia.POOL_ADDRESSES_PROVIDER));
            console2.log("Deployed FlashLoanExecutor:", executor);
        }

        // (2) Gather params from env
        address asset = vm.envAddress("FLASH_ASSET"); // e.g., USDC/WETH/WBTC on Sepolia
        uint256 amount = vm.envUint("FLASH_AMOUNT"); // base units
        address feePayer = vm.envAddress("FEE_PAYER"); // typically your EOA
        uint16 referral = uint16(_envUintOr("REFERRAL_CODE", 0));

        // Optional target call (router/aggregator); safe to omit on Sepolia
        address target = _envAddrOrZero("FLASH_TARGET"); // optional
        bytes memory data = _envBytesOrEmpty("FLASH_DATA"); // optional
        bool approveTgt = _envBoolOr("FLASH_APPROVE_TARGET", false);

        FlashLoanExecutor(executor).initiateFlashLoan(asset, amount, feePayer, target, data, approveTgt, referral);

        vm.stopBroadcast();

        console2.log("Flash loan requested");
        console2.log("  executor :", executor);
        console2.log("  asset    :", asset);
        console2.log("  amount   :", amount);
        console2.log("  feePayer :", feePayer);
        console2.log("  target   :", target);
        console2.log("  approveT :", approveTgt);
        console2.log("  referral :", referral);
    }
}
