// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DevOpsTools} from "lib/foundry-devops/src/DevOpsTools.sol";

import {AaveV3MultiAssetStrategy} from "../../src/aave-v3-yield-strategies/AaveV3MultiAssetStrategy.sol";
import {AaveV3Sepolia, AaveV3SepoliaAssets} from "../../src/aave-v3-yield-strategies/libs/AaveV3Sepolia.sol";

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
    address constant DAI  = AaveV3SepoliaAssets.DAI_UNDERLYING;
    address constant LINK = AaveV3SepoliaAssets.LINK_UNDERLYING;
    address constant WETH = AaveV3SepoliaAssets.WETH_UNDERLYING;

    // Decimals (from address book)
    uint8 constant USDC_DECIMALS = AaveV3SepoliaAssets.USDC_DECIMALS;
    uint8 constant WBTC_DECIMALS = AaveV3SepoliaAssets.WBTC_DECIMALS;
    uint8 constant DAI_DECIMALS  = AaveV3SepoliaAssets.DAI_DECIMALS;
    uint8 constant LINK_DECIMALS = AaveV3SepoliaAssets.LINK_DECIMALS;
    uint8 constant WETH_DECIMALS = AaveV3SepoliaAssets.WETH_DECIMALS;

    // ---------- Orchestrator ----------
    /// @notice Run dispatcher controlled by env ACTION:
    /// ACTION= "mint"  -> mintAll()
    /// ACTION= "supply"-> supplyWeth(SUPPLY_AMOUNT, REFERRAL_CODE)
    /// Defaults to "mint" when ACTION missing.
    function run() external {
        string memory action = _getEnvStringOr("ACTION", "mint");

        if (_eq(action, "mint")) {
            mintAll();
        } else if (_eq(action, "supply")) {
            uint256 amount = _getEnvUintOr("SUPPLY_AMOUNT", 1e18); // default 1 WETH
            uint256 rcU    = _getEnvUintOr("REFERRAL_CODE", 0);
            require(rcU <= type(uint16).max, "REFERRAL_CODE too large");
            supplyWeth(amount, uint16(rcU));
        } else {
            revert(string.concat("Unknown ACTION: ", action));
        }
    }

    // ---------- Entry 1: Mint from Aave Faucet ----------
    /// @notice Mints the faucet’s max amount for each listed token to the deployer EOA.
    function mintAll() public {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address caller = vm.addr(pk);

        vm.startBroadcast(pk);

        uint256 maxUnits = FAUCET.MAX_MINT_AMOUNT();

        _mint(USDC, maxUnits, USDC_DECIMALS, "USDC");
        _mint(WBTC, maxUnits, WBTC_DECIMALS, "WBTC");
        _mint(DAI,  maxUnits, DAI_DECIMALS,  "DAI");
        _mint(LINK, maxUnits, LINK_DECIMALS, "LINK");
        _mint(WETH, maxUnits, WETH_DECIMALS, "WETH"); // wrapped ETH (not native ETH)

        vm.stopBroadcast();

        // Post-mint balances
        console2.log("--- Post-mint balances for caller ---");
        console2.log("caller       :", caller);
        console2.log("USDC balance :", IERC20(USDC).balanceOf(caller));
        console2.log("WBTC balance :", IERC20(WBTC).balanceOf(caller));
        console2.log("DAI  balance :", IERC20(DAI).balanceOf(caller));
        console2.log("LINK balance :", IERC20(LINK).balanceOf(caller));
        console2.log("WETH balance :", IERC20(WETH).balanceOf(caller));
    }

    /// @notice Helper to scale and call faucet.mint.
    function _mint(address token, uint256 units, uint8 decimals, string memory sym) internal {
        uint256 amt = units * (10 ** uint256(decimals));
        uint256 minted = FAUCET.mint(token, msg.sender, amt);
        // Some faucet implementations return minted amount; not all. Log anyway.
        console2.log("Minted %s -> request: %s, return: %s", sym, amt, minted);
    }

    // ---------- Entry 2: Supply WETH to your Strategy ----------
    /// @notice Approves the strategy and calls `supplyAmount(WETH, amount, referral)`.
    /// @param amount Amount of WETH to supply (base units, e.g. 1e18 = 1 WETH).
    /// @param referralCode Aave referral code (0 if not used).
    function supplyWeth(uint256 amount, uint16 referralCode) public {
        require(amount > 0, "amount=0");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address caller = vm.addr(pk);

        vm.startBroadcast(pk);

        address strategyAddr = _resolveStrategy();
        AaveV3MultiAssetStrategy strat = AaveV3MultiAssetStrategy(payable(strategyAddr));

        // Approve the strategy to pull WETH from the EOA
        IERC20(WETH).approve(address(strat), amount);

        // The strategy will pullFrom(msg.sender) and then supply to Aave on your behalf
        strat.supplyAmount(WETH, amount, referralCode);

        vm.stopBroadcast();

        console2.log("--- Supplied WETH to strategy ---");
        console2.log("strategy :", strategyAddr);
        console2.log("caller   :", caller);
        console2.log("amount   :", amount);
        console2.log("referral :", referralCode);

        // ===== OPTIONAL: detailed post-supply diagnostics =====
        // aToken address for WETH:
        address aToken = strat.getAToken(WETH);
        console2.log("WETH aToken :", aToken);

        // Caller’s withdrawable supply = aToken balance of caller:
        uint256 aBal = IERC20(aToken).balanceOf(caller);
        console2.log("Caller aToken balance (WETH supply) :", aBal);

        // Equivalent via strategy helper (same result):
        // uint256 supplyBal = strat.getSupplyBalanceOfUser(WETH, caller);
        // console2.log("getSupplyBalanceOfUser(WETH, caller):", supplyBal);

        // Health factor after supply:
        uint256 hf = strat.healthFactor(caller);
        console2.log("Health Factor:", hf);

        // Debt token & balance (will be zero if you didn't borrow):
        address vDebt = strat.getVariableDebtToken(WETH);
        uint256 vDebtBal = IERC20(vDebt).balanceOf(caller);
        console2.log("VariableDebtToken(WETH):", vDebt);
        console2.log("Caller variable debt(WETH):", vDebtBal);

        // You can also log pool/provider if needed later:
        // console2.log("Provider:", AaveV3Sepolia.POOL_ADDRESSES_PROVIDER);
        // console2.log("Pool    :", address(strat.pool())); // if pool() public, else from address book
    }

    // ---------- Utils ----------
    function _resolveStrategy() internal view returns (address strategy) {
        // Try env first; if none, fall back to DevOpsTools’ last deployment pointer
        try vm.envAddress("STRATEGY") returns (address s) {
            if (s != address(0)) return s;
        } catch {}
        strategy = DevOpsTools.get_most_recent_deployment("AaveV3MultiAssetStrategy", block.chainid);
        require(strategy != address(0), "strategy not found; set STRATEGY env");
    }

    function _getEnvStringOr(string memory key, string memory def) internal view returns (string memory v) {
        try vm.envString(key) returns (string memory s) {
            return s;
        } catch {
            return def;
        }
    }

    function _getEnvUintOr(string memory key, uint256 def) internal view returns (uint256 v) {
        try vm.envUint(key) returns (uint256 u) {
            return u;
        } catch {
            return def;
        }
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
