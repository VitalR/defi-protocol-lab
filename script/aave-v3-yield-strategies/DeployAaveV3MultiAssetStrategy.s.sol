// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import { DevOpsTools } from "lib/foundry-devops/src/DevOpsTools.sol";

import { AaveV3Sepolia, AaveV3SepoliaAssets } from "src/aave-v3-yield-strategies/libs/AaveV3Sepolia.sol";
import { AaveV3MultiAssetStrategy } from "src/aave-v3-yield-strategies/AaveV3MultiAssetStrategy.sol";

import { EnvUtils } from "./utils/EnvUtils.s.sol";

/// @title DeployAaveV3MultiAssetStrategy
/// @notice Deploys `AaveV3MultiAssetStrategy` on Ethereum Sepolia and writes a compact JSON report.
/// @dev
/// Env (recommended):
///   - SEPOLIA_RPC
///   - DEPLOYER_PRIVATE_KEY
/// Optionally override allowlists by editing the arrays below.
contract DeployAaveV3MultiAssetStrategyScript is Script, EnvUtils {
    function run() external {
        // --- Load deployer ---
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address defaultAdmin = vm.addr(deployerKey);

        // --- Aave endpoints (vendored constants) ---
        address provider = AaveV3Sepolia.POOL_ADDRESSES_PROVIDER;
        address dataProvider = AaveV3Sepolia.AAVE_PROTOCOL_DATA_PROVIDER;

        // --- Allowlists (seed) ---
        address[] memory collateral = new address[](2);
        collateral[0] = AaveV3SepoliaAssets.WETH_UNDERLYING;
        collateral[1] = AaveV3SepoliaAssets.USDC_UNDERLYING;

        address[] memory debt = new address[](1);
        debt[0] = AaveV3SepoliaAssets.USDC_UNDERLYING;

        // --- Deploy ---
        vm.startBroadcast(deployerKey);

        AaveV3MultiAssetStrategy strat = new AaveV3MultiAssetStrategy(
            defaultAdmin, // gets DEFAULT_ADMIN_ROLE, ADMIN_ROLE, PAUSER_ROLE per ctor
            provider, // PoolAddressesProvider
            dataProvider, // ProtocolDataProvider
            collateral,
            debt
        );

        vm.stopBroadcast();

        // --- Console logs ---
        console2.log("=== AaveV3MultiAssetStrategy Deployment ===");
        console2.log("Chain ID          :", block.chainid);
        console2.log("Deployer (admin)  :", defaultAdmin);
        console2.log("Strategy          :", address(strat));
        console2.log("Provider          :", provider);
        console2.log("DataProvider      :", dataProvider);
        console2.log("Collateral[0]     :", collateral[0]);
        console2.log("Collateral[1]     :", collateral[1]);
        console2.log("Debt[0]           :", debt[0]);

        // --- Persist a compact JSON report into ./reports ---
        string memory reportDir = string.concat(vm.projectRoot(), "/reports");
        vm.createDir(reportDir, true);

        // Build JSON pieces
        string memory deployment = "{}";
        deployment = vm.serializeAddress("deployment", "strategy", address(strat));
        deployment = vm.serializeUint("deployment", "chainId", block.chainid);
        deployment = vm.serializeString("deployment", "contract", "AaveV3MultiAssetStrategy");
        deployment = vm.serializeAddress("deployment", "defaultAdmin", defaultAdmin);
        deployment = vm.serializeAddress("deployment", "provider", provider);
        deployment = vm.serializeAddress("deployment", "dataProvider", dataProvider);

        // arrays (serializeAddressArray is not available; build strings manually)
        string memory collateralJson = _addressesToJsonArray(collateral);
        string memory debtJson = _addressesToJsonArray(debt);

        // Wrap into a single payload { deployment: {...}, config: {...} }
        string memory configJson = string.concat("{\"collateral\":", collateralJson, ",\"debt\":", debtJson, "}");
        string memory payload = string.concat("{\"deployment\":", deployment, ",\"config\":", configJson, "}");

        // Rolling pointer (latest)
        string memory file = string.concat(reportDir, "/deployment-", vm.toString(block.chainid), ".json");
        vm.writeJson(payload, file);

        // Versioned history (by block number)
        string memory fileVersioned = string.concat(
            reportDir, "/deployment-", vm.toString(block.chainid), "-", vm.toString(block.number), ".json"
        );
        vm.writeJson(payload, fileVersioned);

        // Example: how you might retrieve the latest deployment elsewhere
        // address mostRecent = DevOpsTools.get_most_recent_deployment("AaveV3MultiAssetStrategy", block.chainid);
        // console2.log("Most recent (DevOpsTools):", mostRecent);
    }

    // /// @dev Utility to JSON-encode an array of addresses → ["0x..","0x.."]
    // function _addressesToJsonArray(address[] memory arr) internal pure returns (string memory) {
    //     bytes memory out = bytes("[");
    //     for (uint256 i = 0; i < arr.length; ++i) {
    //         out = abi.encodePacked(out, "\"", _toHexString(arr[i]), "\"");
    //         if (i + 1 < arr.length) {
    //             out = abi.encodePacked(out, ",");
    //         }
    //     }
    //     out = abi.encodePacked(out, "]");
    //     return string(out);
    // }

    // /// @dev Address → 0x-prefixed hex string
    // function _toHexString(address a) internal pure returns (string memory) {
    //     bytes20 data = bytes20(a);
    //     bytes memory hexChars = "0123456789abcdef";
    //     bytes memory str = new bytes(42);
    //     str[0] = "0";
    //     str[1] = "x";
    //     for (uint256 i = 0; i < 20; i++) {
    //         str[2 + i * 2] = hexChars[uint8(data[i] >> 4)];
    //         str[3 + i * 2] = hexChars[uint8(data[i] & 0x0f)];
    //     }
    //     return string(str);
    // }
}
