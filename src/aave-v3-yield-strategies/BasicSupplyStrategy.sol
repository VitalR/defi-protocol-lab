// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IPool, IPoolAddressesProvider } from "./interfaces/IAaveV3.sol";
import { TokenActions } from "./libs/TokenActions.sol";

/// @title BasicSupplyStrategy
/// @notice Minimal Aave V3 integration for supplying, enabling collateral, borrowing, repaying, and withdrawing.
/// @dev - Upgrade-safe: resolves the Pool via PoolAddressesProvider at construction.
///      - Uses OZ v5 SafeERC20 + TokenActions (fee-on-transfer safe + USDT-style approvals).
///      - Admin is role-based (AccessControl) and can pause/unpause all user actions.
contract BasicSupplyStrategy is AccessControl, Pausable {
    using SafeERC20 for IERC20;

    // =============================================================
    //                 IMMUTABLE CONFIGURATION & ROLES
    // =============================================================

    /// @notice Aave V3 Pool entrypoint for the chosen market.
    IPool public immutable pool;

    /// @notice Underlying ERC-20 asset handled by this strategy instance (e.g., USDC).
    address public immutable asset;

    /// @notice Role for admins strategy configuration.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Role for pausers (pause/unpause user actions).
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // =============================================================
    //                      EVENTS & ERRORS
    // =============================================================

    /// @notice Emitted once at construction.
    /// @param admin The address granted DEFAULT_ADMIN_ROLE.
    /// @param provider The PoolAddressesProvider used to resolve the Pool.
    /// @param pool The resolved Aave Pool proxy address.
    /// @param asset The ERC-20 asset managed by this strategy.
    event StrategyInitialized(address indexed admin, address indexed provider, address indexed pool, address asset);

    /// @notice Emitted when a user supplies a specific requested amount.
    /// @param user The caller providing funds.
    /// @param asset The ERC-20 asset supplied.
    /// @param requested The requested amount to pull from the user.
    /// @param received The actual amount received (fee-on-transfer safe) and supplied.
    /// @param referralCode Aave referral code used.
    event SuppliedAmount(
        address indexed user, address indexed asset, uint256 requested, uint256 received, uint16 referralCode
    );

    /// @notice Emitted when a user supplies their entire wallet balance of `asset`.
    /// @param user The caller providing funds.
    /// @param asset The ERC-20 asset supplied.
    /// @param received The actual amount received and supplied.
    /// @param referralCode Aave referral code used.
    event SuppliedMax(address indexed user, address indexed asset, uint256 received, uint16 referralCode);

    /// @notice Emitted when a user enables an asset as collateral.
    /// @param user The caller enabling collateral.
    /// @param asset The ERC-20 asset being enabled.
    event CollateralEnabled(address indexed user, address indexed asset);

    /// @notice Emitted when a user withdraws their full aToken balance.
    /// @param user The recipient of withdrawn funds.
    /// @param asset The ERC-20 asset withdrawn.
    /// @param amount The actual amount withdrawn to the user.
    event WithdrawnAll(address indexed user, address indexed asset, uint256 amount);

    /// @notice Emitted when a user borrows at variable rate.
    /// @param user The debt receiver / borrower.
    /// @param debtAsset The ERC-20 debt asset borrowed.
    /// @param amount The borrowed amount.
    /// @param interestRateMode The interest mode used (2 = variable).
    event Borrowed(address indexed user, address indexed debtAsset, uint256 amount, uint256 interestRateMode);

    /// @notice Emitted when a user repays variable-rate debt.
    /// @param user The debtor whose debt is reduced.
    /// @param debtAsset The ERC-20 debt asset repaid.
    /// @param repaid The actual amount repaid (fee-on-transfer safe).
    /// @param interestRateMode The interest mode used for repayment (2 = variable).
    event Repaid(address indexed user, address indexed debtAsset, uint256 repaid, uint256 interestRateMode);

    /// @notice Thrown when an operation requires positive funds but none were provided/received.
    error NO_FUNDS();

    /// @notice Thrown when a zero address is passed where a non-zero address is required.
    error ZERO_ADDRESS();

    /// @notice Thrown when a zero amount is passed where a positive value is required.
    error ZERO_AMOUNT();

    // =============================================================
    //                       CONSTRUCTOR
    // =============================================================

    /// @notice Construct the strategy by resolving the Pool from the provider and setting the admin.
    /// @param _admin Address that will receive DEFAULT_ADMIN_ROLE (can pause/unpause).
    /// @param _provider Aave V3 PoolAddressesProvider for the target market (e.g., Sepolia).
    /// @param _asset ERC-20 asset to be supplied/withdrawn (e.g., USDC).
    constructor(address _admin, address _provider, address _asset) AccessControl() {
        require(_admin != address(0), ZERO_ADDRESS());
        address poolAddr = IPoolAddressesProvider(_provider).getPool();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);

        pool = IPool(poolAddr);
        asset = _asset;

        emit StrategyInitialized(_admin, _provider, poolAddr, _asset);
    }

    // =============================================================
    //                        USER ACTIONS
    // =============================================================

    /// @notice Pull exactly `_amount` of `asset` from the caller, approve the Pool for the *received* amount, and
    /// supply on behalf of the caller.
    /// @dev Supports fee-on-transfer tokens via balance delta in TokenActions.
    /// @param _amount Requested amount to pull (actual `received` may be less for fee-on-transfer tokens).
    /// @param _referralCode Optional Aave referral code (0 if not used).
    function supplyAmount(uint256 _amount, uint16 _referralCode) external whenNotPaused {
        require(_amount > 0, ZERO_AMOUNT());

        uint256 received = TokenActions.pullFrom(IERC20(asset), msg.sender, _amount);
        require(received > 0, NO_FUNDS());

        TokenActions.approveExact(IERC20(asset), address(pool), received);
        pool.supply(asset, received, msg.sender, _referralCode);

        emit SuppliedAmount(msg.sender, asset, _amount, received, _referralCode);
    }

    /// @notice Pull the caller’s full balance of `asset`, approve the Pool for the *actual* received amount, then
    /// supply on behalf of the caller.
    /// @param _referralCode Optional Aave referral code (0 if not used).
    function supplyMax(uint16 _referralCode) external whenNotPaused {
        uint256 received = TokenActions.pullAllAndApproveExact(IERC20(asset), msg.sender, address(pool));
        require(received > 0, NO_FUNDS());

        pool.supply(asset, received, msg.sender, _referralCode);

        emit SuppliedMax(msg.sender, asset, received, _referralCode);
    }

    /// @notice Enable the supplied `asset` as collateral for the caller inside Aave.
    /// @dev The caller must hold a positive aToken balance for `asset`.
    function enableCollateral() external whenNotPaused {
        pool.setUserUseReserveAsCollateral(asset, true);
        emit CollateralEnabled(msg.sender, asset);
    }

    /// @notice Withdraw the caller’s entire aToken balance for `asset` to their wallet.
    /// @dev Uses `type(uint256).max` per Aave semantics to withdraw full balance.
    function withdrawAll() external whenNotPaused {
        uint256 amount = pool.withdraw(asset, type(uint256).max, msg.sender);
        emit WithdrawnAll(msg.sender, asset, amount);
    }

    /// @notice Borrow an asset at variable rate (interestRateMode = 2) on behalf of the caller.
    /// @dev Caller must have adequate collateral and HF.
    /// @param _debtAsset The ERC-20 debt asset to borrow (e.g., USDC).
    /// @param _amount The amount to borrow (must be > 0).
    function borrowVariable(address _debtAsset, uint256 _amount) external whenNotPaused {
        require(_amount > 0, ZERO_AMOUNT());
        pool.borrow(_debtAsset, _amount, 2, 0, msg.sender);
        emit Borrowed(msg.sender, _debtAsset, _amount, 2);
    }

    /// @notice Repay variable-rate debt (mode = 2) for the caller using tokens pulled from the caller.
    /// @dev Pulls `_amount`, approves Pool for the *received* amount, repays that amount (fee-on-transfer safe).
    /// @param _debtAsset The borrowed ERC-20 asset to repay (e.g., USDC).
    /// @param _amount The intended repayment amount to pull from the caller (must be > 0).
    function repayVariable(address _debtAsset, uint256 _amount) external whenNotPaused {
        require(_amount > 0, ZERO_AMOUNT());

        uint256 received = TokenActions.pullFrom(IERC20(_debtAsset), msg.sender, _amount);
        require(received > 0, NO_FUNDS());

        TokenActions.approveExact(IERC20(_debtAsset), address(pool), received);
        pool.repay(_debtAsset, received, 2, msg.sender);

        emit Repaid(msg.sender, _debtAsset, received, 2);
    }

    // =============================================================
    //                        ADMIN ACTIONS
    // =============================================================

    /// @notice Pause all user actions.
    /// @dev Only DEFAULT_ADMIN_ROLE can call. Emits {Paused} from OZ Pausable.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause all user actions.
    /// @dev Only DEFAULT_ADMIN_ROLE can call. Emits {Unpaused} from OZ Pausable.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =============================================================
    //                    EXTERNAL / VIEW HELPERS
    // =============================================================

    /// @notice Return the current Health Factor for a given user.
    /// @param _user The address of the Aave user.
    /// @return hf The user’s current Health Factor (wad, 1e18 = 1.0).
    function healthFactor(address _user) external view returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(_user);
    }
}
