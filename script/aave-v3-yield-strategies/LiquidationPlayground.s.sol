// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { AaveV3Sepolia, AaveV3SepoliaAssets } from "../../src/aave-v3-yield-strategies/libs/AaveV3Sepolia.sol";
import { IPool, IAaveOracle } from "../../src/aave-v3-yield-strategies/interfaces/IAaveV3.sol";
import { IAaveProtocolDataProvider } from "../../src/aave-v3-yield-strategies/interfaces/IAaveProtocolDataProvider.sol";

import { EnvUtils } from "../utils/EnvUtils.s.sol";

/// @title LiquidationPlayground (Aave V3 - Sepolia)
/// @notice Test/ops helper to (1) simulate liquidation math, (2) create a risky position (testing),
///         and (3) execute liquidation via IPool.liquidationCall. For forks/testnets only.
contract LiquidationPlayground is Script, EnvUtils {
    // ---------- Wiring ----------
    IPool constant POOL = IPool(AaveV3Sepolia.POOL);
    IAaveOracle constant ORACLE = IAaveOracle(AaveV3Sepolia.ORACLE);
    IAaveProtocolDataProvider constant DATA = IAaveProtocolDataProvider(AaveV3Sepolia.AAVE_PROTOCOL_DATA_PROVIDER);

    // Example handy constants
    address constant USDC = AaveV3SepoliaAssets.USDC_UNDERLYING;
    address constant WETH = AaveV3SepoliaAssets.WETH_UNDERLYING;
    address constant WBTC = AaveV3SepoliaAssets.WBTC_UNDERLYING;

    uint256 constant BASE_UNIT = 1e8; // Aave base currency (USD-like) decimals

    // Storage only used for quick prints; can be locals as well.
    uint256 liqThresholdBps;
    uint256 liqBonusBps;
    uint256 collDecimals;
    bool borrowingEnabled;
    bool isActive;
    bool isFrozen;

    // ---------- Dispatcher ----------
    /// @dev ACTION=simulate|create|liquidate (optional; otherwise call the function with --sig)
    function run() external {
        string memory action;
        try vm.envString("ACTION") returns (string memory a) {
            action = a;
        } catch { }

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        if (_eq(action, "simulate")) {
            console2.log("[run] simulate - provide explicit SIG in CLI for specific user/coll/debt");
        } else if (_eq(action, "create")) {
            console2.log("[run] create - provide explicit SIG in CLI with amounts/percents");
        } else if (_eq(action, "liquidate")) {
            console2.log("[run] liquidate - provide explicit SIG in CLI with repay amount");
        } else {
            console2.log("[run] no ACTION set; call specific function with --sig");
        }

        vm.stopBroadcast();
    }

    // ============================================================
    // 1) SIMULATION: show whether `user` can be liquidated & math
    // ============================================================
    function simulateLiquidation(address collateral, address debtAsset, address user) public {
        console2.log("=== Simulate Liquidation ===");
        console2.log("collateral :", collateral);
        console2.log("debtAsset  :", debtAsset);
        console2.log("user       :", user);

        _logAccountData(user);

        (,,,,, uint256 hf) = POOL.getUserAccountData(user);
        bool liquidatable = (hf < 1e18);
        console2.log("LIQUIDATABLE              :", liquidatable);

        // Debt info
        (,, address vDebt) = DATA.getReserveTokensAddresses(debtAsset);
        uint256 userDebtTokens = IERC20(vDebt).balanceOf(user);
        uint256 pxDebt = ORACLE.getAssetPrice(debtAsset); // 1e8
        console2.log("user varDebt balance      :", userDebtTokens);
        console2.log("debt price (1e8)          :", pxDebt);

        // Collateral info & bonus (use helper to avoid tuple/stack issues)
        {
            uint256 decs;
            bool borrowEn;
            bool active;
            bool frozen;
            (decs, liqThresholdBps, liqBonusBps, borrowEn, active, frozen) = _readConfig(collateral);
            collDecimals = decs;
            borrowingEnabled = borrowEn;
            isActive = active;
            isFrozen = frozen;
        }

        uint256 pxColl = ORACLE.getAssetPrice(collateral); // 1e8
        console2.log("coll price  (1e8)         :", pxColl);
        console2.log("coll decimals             :", collDecimals);
        console2.log("liq bonus (bps)           :", liqBonusBps);

        // Close factor estimate
        uint256 closeFactorBps = _envUintOr("CLOSE_FACTOR_BPS", 5000);
        console2.log("closeFactor (bps, est)    :", closeFactorBps);

        // Max debt to cover in tokens (bounded by close factor)
        uint256 maxToCover = Math.mulDiv(userDebtTokens, closeFactorBps, 10_000);
        console2.log("max debt to cover (tokens):", maxToCover);

        // Value to repay (base currency)
        uint256 repayValueBase = Math.mulDiv(maxToCover, pxDebt, 10 ** IERC20Metadata(debtAsset).decimals());
        console2.log("repay value base (1e8)    :", repayValueBase);

        // Collateral to seize (includes bonus): repayValue/pxColl * 10^collDecimals * (liqBonusBps/10000)
        uint256 seized = Math.mulDiv(repayValueBase, 10 ** collDecimals, pxColl) * liqBonusBps / 10_000;
        console2.log("seized collateral (tokens):", seized);

        console2.log("=== Simulation Complete ===");
    }

    // =====================================================================
    // 2) CREATE a risky position (testing/fork only) for a given user (EOA)
    // =====================================================================
    function createLiquidatablePosition(
        address collateral,
        address debtAsset,
        uint256 collateralAmount,
        uint16 borrowPctOfLiqThresholdBps
    ) public {
        require(collateralAmount > 0, "collateralAmount=0");
        require(borrowPctOfLiqThresholdBps > 0 && borrowPctOfLiqThresholdBps <= 10_000, "bad borrow %");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        console2.log("=== Create Risky Position ===");
        console2.log("collateral     :", collateral);
        console2.log("debtAsset      :", debtAsset);
        console2.log("collateral amt :", collateralAmount);
        console2.log("borrow % of LT :", borrowPctOfLiqThresholdBps);

        // 1) Approve + supply collateral (from EOA)
        IERC20(collateral).approve(address(POOL), 0);
        IERC20(collateral).approve(address(POOL), collateralAmount);
        POOL.supply(collateral, collateralAmount, msg.sender, 0);
        console2.log("supplied collateral");

        // 2) Enable collateral
        POOL.setUserUseReserveAsCollateral(collateral, true);
        console2.log("enabled as collateral");

        // 3) Compute borrow size ~= liquidation threshold * pct
        uint256 pxColl = ORACLE.getAssetPrice(collateral); // 1e8
        uint256 pxDebt = ORACLE.getAssetPrice(debtAsset); // 1e8

        uint256 localCollDecimals;
        {
            uint256 decs;
            bool borrowEn;
            bool active;
            bool frozen;
            (decs, liqThresholdBps, liqBonusBps, borrowEn, active, frozen) = _readConfig(collateral);
            require(borrowEn && active && !frozen, "coll reserve not borrow-active");
            localCollDecimals = decs;
        }

        uint256 collValueBase = Math.mulDiv(collateralAmount, pxColl, 10 ** localCollDecimals); // 1e8
        uint256 maxDebtAtThresholdBase = Math.mulDiv(collValueBase, liqThresholdBps, 10_000);
        uint256 borrowValueBase = Math.mulDiv(maxDebtAtThresholdBase, borrowPctOfLiqThresholdBps, 10_000);

        // Convert to debt token units
        uint8 debtDec = IERC20Metadata(debtAsset).decimals();
        uint256 borrowAmount = Math.mulDiv(borrowValueBase, 10 ** debtDec, pxDebt);

        // 4) Borrow at variable
        POOL.borrow(debtAsset, borrowAmount, 2, 0, msg.sender);
        console2.log("borrowed debt  :", borrowAmount);

        (,,,,, uint256 hfAfter) = POOL.getUserAccountData(msg.sender);
        console2.log("HF after       :", hfAfter);

        console2.log("=== Risky Position Created ===");
        vm.stopBroadcast();
    }

    // ================================================================
    // 3) LIQUIDATE: repay debtor’s variable debt & seize collateral
    // ================================================================
    function liquidate(address collateral, address debtAsset, address user, uint256 repayAmount, bool receiveAToken)
        public
    {
        require(repayAmount > 0, "repayAmount=0");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        console2.log("=== Liquidation ===");
        console2.log("collateral :", collateral);
        console2.log("debtAsset  :", debtAsset);
        console2.log("user       :", user);
        console2.log("repay amt  :", repayAmount);
        console2.log("recv aToken:", receiveAToken);

        (,,,,, uint256 hf) = POOL.getUserAccountData(user);
        require(hf < 1e18, "user not liquidatable (HF >= 1)");

        IERC20(debtAsset).approve(address(POOL), 0);
        IERC20(debtAsset).approve(address(POOL), repayAmount);
        console2.log("approved Pool for debtAsset");

        POOL.liquidationCall(collateral, debtAsset, user, repayAmount, receiveAToken);
        console2.log("liquidationCall executed");

        (,,,,, uint256 hfAfter) = POOL.getUserAccountData(user);
        console2.log("user HF after:", hfAfter);

        uint256 collBal = IERC20(collateral).balanceOf(msg.sender);
        console2.log("your collateral bal:", collBal);

        vm.stopBroadcast();
        console2.log("=== Liquidation Done ===");
    }

    // ---------- Helpers ----------
    function _logAccountData(address user) internal view {
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 hf
        ) = POOL.getUserAccountData(user);

        console2.log("HF                        :", hf);
        console2.log("totalCollateralBase (1e8) :", totalCollateralBase);
        console2.log("totalDebtBase      (1e8)  :", totalDebtBase);
        console2.log("availableBorrowsBase(1e8) :", availableBorrowsBase);
        console2.log("liqThreshold (bps)        :", currentLiquidationThreshold);
        console2.log("ltv (bps)                 :", ltv);
    }

    function _readConfig(address asset)
        internal
        view
        returns (
            uint256 decimals_,
            uint256 liqThresholdBps_,
            uint256 liqBonusBps_,
            bool borrowingEnabled_,
            bool isActive_,
            bool isFrozen_
        )
    {
        (
            decimals_,
            , // ltv (unused)
            liqThresholdBps_,
            liqBonusBps_,
            , // reserveFactor (unused)
            , // usageAsCollateralEnabled (unused)
            borrowingEnabled_,
            , // stableBorrowRateEnabled (unused)
            isActive_,
            isFrozen_
        ) = DATA.getReserveConfigurationData(asset);
    }
}
