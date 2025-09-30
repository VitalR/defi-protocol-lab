// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { DevOpsTools } from "lib/foundry-devops/src/DevOpsTools.sol";

import { AaveV3MultiAssetStrategy } from "../../src/aave-v3-yield-strategies/AaveV3MultiAssetStrategy.sol";
import { AaveV3Sepolia, AaveV3SepoliaAssets } from "../../src/aave-v3-yield-strategies/libs/AaveV3Sepolia.sol";

/// @dev Aave Sepolia faucet:
///      0xC959483DBa39aa9E78757139af0e9a2EDEb3f42D
interface IAaveFaucet {
    function MAX_MINT_AMOUNT() external view returns (uint256);
    function mint(address token, address to, uint256 amount) external returns (uint256);
}

contract ExecuteAaveV3FaucetAndSupplyScript is Script {
    // ---------- Wiring ----------
    IAaveFaucet constant FAUCET = IAaveFaucet(address(AaveV3Sepolia.FAUCET));

    // Underlyings
    address constant USDC = AaveV3SepoliaAssets.USDC_UNDERLYING;
    address constant WBTC = AaveV3SepoliaAssets.WBTC_UNDERLYING;
    address constant DAI = AaveV3SepoliaAssets.DAI_UNDERLYING;
    address constant LINK = AaveV3SepoliaAssets.LINK_UNDERLYING;
    address constant WETH = AaveV3SepoliaAssets.WETH_UNDERLYING;

    // Decimals (from address book)
    uint8 constant USDC_DECIMALS = AaveV3SepoliaAssets.USDC_DECIMALS;
    uint8 constant WBTC_DECIMALS = AaveV3SepoliaAssets.WBTC_DECIMALS;
    uint8 constant DAI_DECIMALS = AaveV3SepoliaAssets.DAI_DECIMALS;
    uint8 constant LINK_DECIMALS = AaveV3SepoliaAssets.LINK_DECIMALS;
    uint8 constant WETH_DECIMALS = AaveV3SepoliaAssets.WETH_DECIMALS;

    // ---------- Orchestrator ----------
    /// @notice Run dispatcher controlled by env ACTION:
    /// ACTION= "mint"  -> mintAll()
    /// ACTION= "supply"-> supplyToken(TOKEN, SUPPLY_AMOUNT, REFERRAL_CODE, SET_COLLATERAL)
    function run() external {
        // mintAll();
        // Example: supply 1 WBTC and set as collateral
        supplyToken(WBTC, 1e8, 0, true); // 1 WBTC (8 decimals)
            // borrowToken(WBTC, 0);
            // repayAllDebt(WBTC);
    }

    // ---------- Entry 1: Mint from Aave Faucet ----------
    /// @notice Mints the faucet’s max amount for each listed token to the deployer EOA.
    function mintAll() public {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        uint256 maxUnits = FAUCET.MAX_MINT_AMOUNT();

        _mintSafe(USDC, maxUnits, USDC_DECIMALS, "USDC");
        _mintSafe(WBTC, maxUnits, WBTC_DECIMALS, "WBTC");
        _mintSafe(DAI, maxUnits, DAI_DECIMALS, "DAI");
        _mintSafe(LINK, maxUnits, LINK_DECIMALS, "LINK");

        // bool mintedWeth = _mintSafe(WETH, maxUnits, WETH_DECIMALS, "WETH");
        // if (!mintedWeth) {
        //     uint256 wrapWei = _envUintOrDefault("WRAP_WEI", 1 ether);
        //     IWETH(WETH).deposit{value: wrapWei}();
        //     console2.log("Wrapped WETH: %s wei", wrapWei);
        // }

        vm.stopBroadcast();
    }

    // ---------- Entry 2: Supply tokens to Strategy ----------
    /// @notice Supply any token to the strategy, optionally marking it as collateral.
    /// @param token ERC20 to supply (must be allowed by the strategy).
    /// @param amount Amount in base units (e.g. 1e18 for WETH, 1e8 for WBTC, 1e6 for USDC).
    /// @param referralCode Aave referral code (0 if not used).
    /// @param setCollateral If true, will call setCollateralAllowedBatch([token], true) before supply.
    function supplyToken(address token, uint256 amount, uint16 referralCode, bool setCollateral) public {
        require(amount > 0, "amount=0");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        address strategyAddr = _resolveStrategy();
        AaveV3MultiAssetStrategy strat = AaveV3MultiAssetStrategy(payable(strategyAddr));

        if (setCollateral) {
            address[] memory tokens = new address[](1);
            tokens[0] = token;
            strat.setCollateralAllowedBatch(tokens, true);
            console2.log("Set token as collateral:", token);
        }

        IERC20(token).approve(address(strat), amount);
        strat.supplyAmount(token, amount, referralCode);

        // --------- Logs ----------
        address aToken = strat.getAToken(token);
        uint256 aBalUser = IERC20(aToken).balanceOf(msg.sender);
        uint256 hf = strat.healthFactor(msg.sender);

        vm.stopBroadcast();

        console2.log("=== Supplied Token ===");
        console2.log("  strategy      :", strategyAddr);
        console2.log("  token         :", token);
        console2.log("  aToken        :", aToken);
        console2.log("  user aTokenBal:", aBalUser);
        console2.log("  healthFactor  :", hf);
        console2.log("  amount        :", amount);
        console2.log("  referral      :", referralCode);
    }

    // ---------- Entry 3: Borrow tokens from Strategy ----------
    /// @notice Borrow any token from the strategy, optionally setting it as debt.
    /// @param token ERC20 to borrow (must be allowed by the strategy).
    /// @param referralCode Aave referral code (0 if not used).
    function borrowToken(address token, uint16 referralCode) public {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        address strategyAddr = _resolveStrategy();
        AaveV3MultiAssetStrategy strat = AaveV3MultiAssetStrategy(payable(strategyAddr));

        console2.log("=== Borrow Flow ===");
        console2.log("  strategy        :", strategyAddr);
        console2.log("  token           :", token);

        // 1. Allowlist token as debt
        address[] memory arr = new address[](1);
        arr[0] = token;
        strat.setDebtAllowedBatch(arr, true);
        console2.log("  debt allowlisted :", token);

        // 2. Sanity check
        bool allowed = strat.isDebtAllowed(token);
        require(allowed, "Token not debt-allowed");

        // 3. Approximate max borrow
        uint256 maxBorrow = strat.approxMaxBorrow(token);
        uint256 buffer = (maxBorrow * 90) / 100; // 90% buffer
        console2.log("  max borrow approx   :", maxBorrow);
        console2.log("  with buffer (90%)   :", buffer);

        // 4. Check health factor before
        uint256 hfBefore = strat.healthFactor(msg.sender);
        console2.log("  health factor (before) :", hfBefore);

        // 5. Borrow (variable)
        strat.borrowVariable(token, buffer, referralCode);
        console2.log("  borrow executed     :", buffer);

        // 6. Debt balance & HF after
        uint256 debt = strat.getVariableDebtBalanceOfUser(token, msg.sender);
        uint256 hfAfter = strat.healthFactor(msg.sender);

        console2.log("  debt balance (var)    :", debt);
        console2.log("  health factor (after) :", hfAfter);

        vm.stopBroadcast();
    }

    // ---------- Entry 4: Repay an exact AMOUNT of variable debt for `token` ----------
    function repayAmount(address token, uint256 amount) public {
        require(amount > 0, "amount=0");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        address strategyAddr = _resolveStrategy();
        AaveV3MultiAssetStrategy strat = AaveV3MultiAssetStrategy(payable(strategyAddr));

        console2.log("=== Repay-Amount Flow ===");
        console2.log("  strategy                :", strategyAddr);
        console2.log("  token                   :", token);
        console2.log("  amount                  :", amount);

        // Ensure token is debt-allowed (idempotent)
        if (!strat.isDebtAllowed(token)) {
            address[] memory arr = new address[](1);
            arr[0] = token;
            strat.setDebtAllowedBatch(arr, true);
            console2.log("  debt allowlisted        :", token);
        }

        // Debt & HF before
        uint256 debtBefore = strat.getVariableDebtBalanceOfUser(token, msg.sender);
        uint256 hfBefore = strat.healthFactor(msg.sender);
        console2.log("  debt before repay       :", debtBefore);
        console2.log("  health factor (before)  :", hfBefore);

        // User must hold/approve at least `amount`
        uint256 walletBal = IERC20(token).balanceOf(msg.sender);
        console2.log("  wallet balance          :", walletBal);
        require(walletBal >= amount, "insufficient wallet balance");

        // Approve pull -> strategy.repayVariable(token, amount)
        IERC20(token).approve(strategyAddr, 0);
        IERC20(token).approve(strategyAddr, amount);
        console2.log("  approved to strat       :", amount);

        strat.repayVariable(token, amount);
        console2.log("  repay executed          :", amount);

        // Debt & HF after
        uint256 debtAfter = strat.getVariableDebtBalanceOfUser(token, msg.sender);
        uint256 hfAfter = strat.healthFactor(msg.sender);

        vm.stopBroadcast();

        console2.log("  debt after repay        :", debtAfter);
        console2.log("  health factor (after)   :", hfAfter);
        console2.log("=== Repay-Amount Flow: complete ===");
    }

    /// @notice Fully repay variable-rate debt for `token` using the strategy’s repay-all helper.
    /// @dev Ensures `token` is debt-allowed, logs HF & balances before/after.
    function repayAllToken(address token) public {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        address strategyAddr = _resolveStrategy();
        AaveV3MultiAssetStrategy strat = AaveV3MultiAssetStrategy(payable(strategyAddr));

        console2.log("=== Repay All (Variable) ===");
        console2.log("  strategy        :", strategyAddr);
        console2.log("  token           :", token);

        // 0) Ensure token is debt-allowed (idempotent)
        address[] memory arr = new address[](1);
        arr[0] = token;
        strat.setDebtAllowedBatch(arr, true);
        require(strat.isDebtAllowed(token), "Token not debt-allowed");

        // 1) Snapshot before
        uint256 hfBefore = strat.healthFactor(msg.sender);
        uint256 debtBefore = strat.getVariableDebtBalanceOfUser(token, msg.sender);
        console2.log("  debt (before)   :", debtBefore);
        console2.log("  HF   (before)   :", hfBefore);

        // 2) Repay all
        uint256 repaid = strat.repayAllVariable(token);
        console2.log("  repaid          :", repaid);

        // 3) Snapshot after
        uint256 debtAfter = strat.getVariableDebtBalanceOfUser(token, msg.sender);
        uint256 hfAfter = strat.healthFactor(msg.sender);
        console2.log("  debt (after)    :", debtAfter);
        console2.log("  HF   (after)    :", hfAfter);

        vm.stopBroadcast();
    }

    // ---------- Utils ----------
    /// @notice Helper to scale and call faucet.mint.
    function _mintSafe(address token, uint256 units, uint8 decimals, string memory sym) internal returns (bool ok) {
        uint256 amt = units * (10 ** decimals);
        try FAUCET.mint(token, msg.sender, amt) returns (uint256 ret) {
            console2.log("Minted %s -> request: %s, return: %s", sym, amt, ret);
            return true;
        } catch {
            console2.log("Faucet cannot mint %s (skipped / fallback if WETH).", sym);
            return false;
        }
    }

    function _resolveStrategy() internal view returns (address strategy) {
        // Try env first; if none, fall back to DevOpsTools’ last deployment pointer
        try vm.envAddress("STRATEGY") returns (address s) {
            if (s != address(0)) return s;
        } catch { }
        strategy = DevOpsTools.get_most_recent_deployment("AaveV3MultiAssetStrategy", block.chainid);
        require(strategy != address(0), "strategy not found; set STRATEGY env");
    }

    function _envUintOrDefault(string memory key, uint256 def) internal view returns (uint256 out) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return def;
        }
    }
}
