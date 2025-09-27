// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAaveProtocolDataProvider } from "./interfaces/IAaveProtocolDataProvider.sol";
import { IPool, IPoolAddressesProvider, IAaveOracle } from "./interfaces/IAaveV3.sol";
import { TokenActions } from "./libs/TokenActions.sol";

/// @title AaveV3MultiAssetStrategy (Multi-Asset, Aave V3)
/// @notice A production-friendly Aave V3 integration supporting multiple assets with admin-managed allowlists.
/// @dev
/// - Supply/withdraw/enableCollateral: gated by `_collateralAllowed`
/// - Borrow/repay (variable-rate): gated by `_debtAllowed`
/// - Pool resolved from `IPoolAddressesProvider` in the constructor (upgrade-safe to Pool impl changes)
/// - Uses `IAaveProtocolDataProvider` to discover aToken / debt token addresses for views
/// - Guards:
///     * AccessControl: `ADMIN_ROLE` (allowlist mgmt), `PAUSER_ROLE` (pause/unpause), `DEFAULT_ADMIN_ROLE` (role admin)
///     * Pausable: all state-changing user actions are `whenNotPaused`
///     * ReentrancyGuard: all state-changing user actions are `nonReentrant`
/// - Token safety:
///     * Pulls from users using balance-delta logic (fee-on-transfer safe)
///     * Uses `forceApprove` semantics under the hood (via TokenActions) for USDT-like tokens
/// - Notes:
///     * Health factor is portfolio-wide in Aave; not per-asset
contract AaveV3MultiAssetStrategy is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // =============================================================
    //                 CONFIGURATION & STORAGE
    // =============================================================

    /// @notice Aave V3 Pool entrypoint for the chosen market.
    IPool public immutable pool;

    /// @notice Aave V3 ProtocolDataProvider (for aToken/debt token discovery).
    IAaveProtocolDataProvider public immutable dataProvider;

    /// @notice Aave price oracle (base currency units, 8 decimals).
    IAaveOracle public immutable oracle;

    /// @dev Aave oracle and account-data values are quoted in a “base currency” with 8 decimals (1e8 = 1.0 base).
    ///      This constant documents that scale. In `approxMaxBorrow` we don’t need to use it explicitly because both
    ///      `availableBorrowsBase` and `getAssetPrice` share the same 1e8 scale and cancel out.
    uint256 private constant BASE_UNIT = 1e8;

    /// @notice Role for admins strategy configuration.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Role for pausers (pause/unpause user actions).
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Assets allowed for supply/withdraw/collateral.
    EnumerableSet.AddressSet private _collateralAllowed;

    /// @notice Assets allowed for borrow/repay (debt assets).
    EnumerableSet.AddressSet private _debtAllowed;

    // =============================================================
    //                      EVENTS & ERRORS
    // =============================================================

    /// @notice Emitted when an asset is added/removed from the collateral allowlist.
    /// @param admin The admin that performed the change.
    /// @param asset The asset address being changed.
    /// @param allowed True when added; false when removed.
    event CollateralAssetAllowlisted(address indexed admin, address indexed asset, bool allowed);

    /// @notice Emitted when an asset is added/removed from the debt allowlist.
    /// @param admin The admin that performed the change.
    /// @param asset The asset address being changed.
    /// @param allowed True when added; false when removed.
    event DebtAssetAllowlisted(address indexed admin, address indexed asset, bool allowed);

    /// @notice Emitted once at construction.
    /// @param admin The address granted DEFAULT_ADMIN_ROLE.
    /// @param provider The PoolAddressesProvider used to resolve the Pool.
    /// @param pool The resolved Aave Pool proxy address.
    event StrategyInitialized(address indexed admin, address indexed provider, address indexed pool);

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

    /// @notice Thrown when an asset is not allowlisted for the requested action.
    error ASSET_NOT_ALLOWED();

    /// @notice Thrown when the buffer basis points are too high.
    error BUFFER_BPS_TOO_HIGH();

    /// @notice Thrown when an operation requires positive funds but none were provided/received.
    error NO_FUNDS();

    /// @notice Thrown when the asset price is zero.
    error PRICE_ZERO();

    /// @notice Thrown when a zero address is passed where a non-zero address is required.
    error ZERO_ADDRESS();

    /// @notice Thrown when a zero amount is passed where a positive value is required.
    error ZERO_AMOUNT();

    /// @notice Thrown when too many assets are passed.
    error TOO_MANY_ASSETS();

    // =============================================================
    //                       MODIFIERS
    // =============================================================

    modifier onlyCollateralAllowed(address _asset) {
        require(_collateralAllowed.contains(_asset), ASSET_NOT_ALLOWED());
        _;
    }

    modifier onlyDebtAllowed(address _asset) {
        require(_debtAllowed.contains(_asset), ASSET_NOT_ALLOWED());
        _;
    }

    // =============================================================
    //                       CONSTRUCTOR
    // =============================================================

    /// @notice Construct the strategy by resolving the Pool, assigning admin, and seeding allowlists (optional).
    /// @param _defaultAdmin Address that will receive DEFAULT_ADMIN_ROLE (can manage access control roles and internal
    /// operations).
    /// @param _provider Address of Aave V3 PoolAddressesProvider for the target market (e.g., Sepolia).
    /// @param _dataProvider Address of Aave V3 ProtocolDataProvider for the target market (e.g., Sepolia).
    /// @param _collateralAssets Initial collateral-allowed assets; can be empty.
    /// @param _debtAssets Initial debt-allowed assets; can be empty.
    constructor(
        address _defaultAdmin,
        address _provider,
        address _dataProvider,
        address[] memory _collateralAssets,
        address[] memory _debtAssets
    ) AccessControl() {
        require(_defaultAdmin != address(0) && _provider != address(0) && _dataProvider != address(0), ZERO_ADDRESS());

        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _grantRole(ADMIN_ROLE, _defaultAdmin);
        _grantRole(PAUSER_ROLE, _defaultAdmin);

        address poolAddr = IPoolAddressesProvider(_provider).getPool();
        pool = IPool(poolAddr);
        dataProvider = IAaveProtocolDataProvider(_dataProvider);

        address oracleAddr = IPoolAddressesProvider(_provider).getPriceOracle();
        oracle = IAaveOracle(oracleAddr);

        _setCollateralAllowedBatch(_collateralAssets, true);
        _setDebtAllowedBatch(_debtAssets, true);

        emit StrategyInitialized(_defaultAdmin, _provider, poolAddr);
    }

    // =============================================================
    //                        USER ACTIONS
    // =============================================================

    /// @notice Pull exactly `_amount` of `asset`, approve Pool for *received* amount, and supply on behalf of caller.
    /// @param _asset The ERC-20 to supply (must be allowlisted in `collateralAllowed`).
    /// @param _amount Requested amount to pull (actual `received` may be less for fee-on-transfer tokens).
    /// @param _referralCode Optional Aave referral code to attribute this action to an integrator. Use 0 if not
    /// applicable.
    function supplyAmount(address _asset, uint256 _amount, uint16 _referralCode)
        external
        whenNotPaused
        onlyCollateralAllowed(_asset)
        nonReentrant
    {
        require(_amount > 0, ZERO_AMOUNT());

        uint256 received = TokenActions.pullFrom(IERC20(_asset), msg.sender, _amount);
        require(received > 0, NO_FUNDS());

        TokenActions.approveExact(IERC20(_asset), address(pool), received);
        pool.supply(_asset, received, msg.sender, _referralCode);

        emit SuppliedAmount(msg.sender, _asset, _amount, received, _referralCode);
    }

    /// @notice Pull the caller’s full balance of `asset`, approve the Pool for the *actual* received amount, then
    /// supply on behalf of the caller.
    /// @param _asset The ERC-20 to supply (must be allowlisted in `collateralAllowed`).
    /// @param _referralCode Optional Aave referral code (0 if not used).
    function supplyMax(address _asset, uint16 _referralCode)
        external
        whenNotPaused
        onlyCollateralAllowed(_asset)
        nonReentrant
    {
        uint256 received = TokenActions.pullAllAndApproveExact(IERC20(_asset), msg.sender, address(pool));
        require(received > 0, NO_FUNDS());

        pool.supply(_asset, received, msg.sender, _referralCode);

        emit SuppliedMax(msg.sender, _asset, received, _referralCode);
    }

    /// @notice Enable the supplied `asset` as collateral for the caller inside Aave.
    /// @dev The caller must hold a positive aToken balance for `asset`.
    /// @param _asset The asset to mark as collateral (must be allowlisted in `collateralAllowed`).
    function enableCollateral(address _asset) external whenNotPaused onlyCollateralAllowed(_asset) {
        pool.setUserUseReserveAsCollateral(_asset, true);
        emit CollateralEnabled(msg.sender, _asset);
    }

    /// @notice Withdraw the caller’s entire aToken balance for `asset` to their wallet.
    /// @dev Uses `type(uint256).max` per Aave semantics to withdraw full balance.
    /// @param _asset The ERC-20 to withdraw (must be allowlisted in `collateralAllowed`).
    function withdrawAll(address _asset) external whenNotPaused onlyCollateralAllowed(_asset) nonReentrant {
        uint256 amount = pool.withdraw(_asset, type(uint256).max, msg.sender);
        emit WithdrawnAll(msg.sender, _asset, amount);
    }

    /// @notice Borrow an asset at variable rate (interestRateMode = 2) on behalf of the caller.
    /// @dev Caller must have adequate collateral and HF.
    /// @param _debtAsset The ERC-20 debt asset to borrow (e.g., USDC).
    /// @param _amount The amount to borrow (must be > 0).
    /// @param _referralCode Optional Aave referral code (0 if unused).
    function borrowVariable(address _debtAsset, uint256 _amount, uint16 _referralCode)
        external
        whenNotPaused
        onlyDebtAllowed(_debtAsset)
        nonReentrant
    {
        require(_amount > 0, ZERO_AMOUNT());
        pool.borrow(_debtAsset, _amount, 2, _referralCode, msg.sender);
        emit Borrowed(msg.sender, _debtAsset, _amount, 2);
    }

    /// @notice Repay variable-rate debt (mode = 2) for the caller using tokens pulled from the caller.
    /// @dev Pulls `_amount`, approves Pool for the *received* amount, repays that amount (fee-on-transfer safe).
    /// @param _debtAsset The borrowed ERC-20 asset to repay (e.g., USDC).
    /// @param _amount The intended repayment amount to pull from the caller (must be > 0).
    function repayVariable(address _debtAsset, uint256 _amount)
        external
        whenNotPaused
        onlyDebtAllowed(_debtAsset)
        nonReentrant
    {
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

    /// @notice Add/remove a single asset to/from the collateral allowlist.
    /// @param _asset The asset to toggle.
    /// @param _allow True to add; false to remove.
    function setCollateralAllowed(address _asset, bool _allow) external onlyRole(ADMIN_ROLE) {
        require(_asset != address(0), ZERO_ADDRESS());
        bool changed = _allow ? _collateralAllowed.add(_asset) : _collateralAllowed.remove(_asset);
        if (changed) emit CollateralAssetAllowlisted(msg.sender, _asset, _allow);
    }

    /// @notice Add/remove a single asset to/from the debt allowlist.
    /// @param _asset The asset to toggle.
    /// @param _allow True to add; false to remove.
    function setDebtAllowed(address _asset, bool _allow) external onlyRole(ADMIN_ROLE) {
        require(_asset != address(0), ZERO_ADDRESS());
        bool changed = _allow ? _debtAllowed.add(_asset) : _debtAllowed.remove(_asset);
        if (changed) emit DebtAssetAllowlisted(msg.sender, _asset, _allow);
    }

    /// @notice Batch add/remove assets in collateral allowlist.
    /// @param _assets The array of assets to toggle.
    /// @param _allow True to add; false to remove.
    function setCollateralAllowedBatch(address[] calldata _assets, bool _allow) external onlyRole(ADMIN_ROLE) {
        address[] memory assets = _assets; // copy to memory
        _setCollateralAllowedBatch(assets, _allow);
    }

    /// @notice Batch add/remove assets in debt allowlist.
    /// @param _assets The array of assets to toggle.
    /// @param _allow True to add; false to remove.
    function setDebtAllowedBatch(address[] calldata _assets, bool _allow) external onlyRole(ADMIN_ROLE) {
        address[] memory assets = _assets;
        _setDebtAllowedBatch(assets, _allow);
    }

    /// @notice Pause all user actions.
    /// @dev Only PAUSER_ROLE can call. Emits {Paused} from OZ Pausable.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause all user actions.
    /// @dev Only PAUSER_ROLE can call. Emits {Unpaused} from OZ Pausable.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =============================================================
    //                    EXTERNAL / VIEW HELPERS
    // =============================================================

    /// @notice Return the current account data for a given user.
    /// @notice Return the current Health Factor for a given user.
    /// @param _user The address of the Aave user.
    /// @return hf The user’s current Health Factor (wad, 1e18 = 1.0).
    function healthFactor(address _user) external view returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(_user);
    }

    /// @notice Return the aToken address for an underlying asset, via ProtocolDataProvider.
    /// @param _asset The asset to check.
    function getAToken(address _asset) public view returns (address aToken) {
        (aToken,,) = dataProvider.getReserveTokensAddresses(_asset);
    }

    /// @notice User’s aToken balance (withdrawable supply) for `asset`.
    /// @param _asset The asset to check.
    /// @param _user The address of the Aave user.
    /// @return The user’s aToken balance (withdrawable supply).
    function getSupplyBalanceOfUser(address _asset, address _user) public view returns (uint256) {
        address aToken = getAToken(_asset);
        return IERC20(aToken).balanceOf(_user);
    }

    /// @notice Convenience: caller’s aToken balance for `asset`.
    /// @param _asset The asset to check.
    /// @return The caller’s aToken balance (withdrawable supply).
    function getSupplyBalance(address _asset) external view returns (uint256) {
        return getSupplyBalanceOfUser(_asset, msg.sender);
    }

    /// @notice Returns whether an asset is allowed for collateral actions.
    /// @param _asset The asset to check.
    /// @return True if the asset is allowed for collateral actions, false otherwise.
    function isCollateralAllowed(address _asset) external view returns (bool) {
        return _collateralAllowed.contains(_asset);
    }

    /// @notice Returns whether an asset is allowed for debt actions.
    /// @param _asset The asset to check.
    /// @return True if the asset is allowed for debt actions, false otherwise.
    function isDebtAllowed(address _asset) external view returns (bool) {
        return _debtAllowed.contains(_asset);
    }

    /// @notice Returns the full list of collateral-allowed assets.
    /// @return The full list of collateral-allowed assets.
    function getAllCollateralAllowed() external view returns (address[] memory) {
        return _collateralAllowed.values();
    }

    /// @notice Returns the full list of debt-allowed assets.
    /// @return The full list of debt-allowed assets.
    function getAllDebtAllowed() external view returns (address[] memory) {
        return _debtAllowed.values();
    }

    /// @notice Returns the variable debt token address for an underlying asset.
    /// @param _asset The asset to check.
    /// @return vDebt The variable debt token address for `_asset`.
    function getVariableDebtToken(address _asset) public view returns (address vDebt) {
        (,, vDebt) = dataProvider.getReserveTokensAddresses(_asset);
    }

    /// @notice Returns the variable debt balance of a user for an underlying asset.
    /// @param _asset The asset to check.
    /// @param _user The address of the Aave user.
    /// @return The variable debt balance of `_user` for `_asset`.
    function getVariableDebtBalanceOfUser(address _asset, address _user) external view returns (uint256) {
        return IERC20(getVariableDebtToken(_asset)).balanceOf(_user);
    }

    /// @notice Approximate the maximum amount of `_asset` that the caller can borrow right now (no buffer).
    /// @dev
    /// - Fetches price from Aave oracle (USD, 8 decimals).
    /// - Reads `availableBorrowsBase` from Aave (USD, 8 decimals).
    /// - Converts USD capacity into token amount:
    ///   amount = (availableBorrowsBase * 10**decimals) / priceUsd
    /// - BASE_UNIT (1e8) is not explicitly needed since both values share the same scale.
    /// @param _asset The debt asset to quote for.
    /// @return maxToken The approximate max amount of `_asset` borrowable (in token base units).
    function approxMaxBorrow(address _asset) public view returns (uint256 maxToken) {
        (,,,, uint256 availableBorrowsBase,) = pool.getUserAccountData(msg.sender);
        return _approxFromBaseCapacity(availableBorrowsBase, _asset);
    }

    /// @notice Approximate the maximum amount of `_asset` that `_user` can borrow right now (no buffer).
    /// @param _user User to check.
    /// @param _asset Debt asset to quote for.
    /// @return maxToken Maximum borrowable amount in token base units.
    function approxMaxBorrowFor(address _user, address _asset) external view returns (uint256 maxToken) {
        (,,,, uint256 availableBorrowsBase,) = pool.getUserAccountData(_user);
        return _approxFromBaseCapacity(availableBorrowsBase, _asset);
    }

    /// @notice Approximate the maximum borrow amount with a safety buffer.
    /// @dev `bufferBps` subtracts a percentage (in basis points) to avoid HF slippage reverts.
    ///      e.g. `bufferBps = 500` => return 95% of raw quote.
    /// @param _asset The debt asset to quote for.
    /// @param _bufferBps Basis points to shave off (0–10_000).
    /// @return safeMaxToken The buffered max amount (token base units).
    function approxMaxBorrowWithBuffer(address _asset, uint16 _bufferBps)
        external
        view
        returns (uint256 safeMaxToken)
    {
        uint256 raw = approxMaxBorrow(_asset);
        if (_bufferBps == 0 || raw == 0) return raw;
        require(_bufferBps <= 10_000, BUFFER_BPS_TOO_HIGH());
        // safeMax = raw * (10000 - bufferBps) / 10000
        safeMaxToken = Math.mulDiv(raw, (10_000 - _bufferBps), 10_000);
    }

    // =============================================================
    //                       INTERNAL HELPERS
    // =============================================================

    /// @dev Shared math: converts a base-currency borrowing capacity (1e8) into token units.
    /// Reverts if oracle price is zero.
    function _approxFromBaseCapacity(uint256 availableBorrowsBase, address _asset) internal view returns (uint256) {
        if (availableBorrowsBase == 0) return 0;

        uint256 px = oracle.getAssetPrice(_asset); // 1e8 base units per 1 token
        if (px == 0) revert PRICE_ZERO();

        uint256 scale = 10 ** uint256(IERC20Metadata(_asset).decimals());
        // (available * scale) / price, avoiding overflow and preserving precision
        return Math.mulDiv(availableBorrowsBase, scale, px);
    }

    /// @notice Internal function to batch add/remove assets in collateral allowlist.
    function _setCollateralAllowedBatch(address[] memory _assets, bool _allow) internal {
        uint256 len = _assets.length;
        require(len < 11, TOO_MANY_ASSETS());
        if (len == 0) return;
        for (uint256 i; i < len; ++i) {
            address a = _assets[i];
            require(a != address(0), ZERO_ADDRESS());
            bool changed = _allow ? _collateralAllowed.add(a) : _collateralAllowed.remove(a);
            if (changed) emit CollateralAssetAllowlisted(msg.sender, a, _allow);
        }
    }

    /// @notice Internal function to batch add/remove assets in debt allowlist.
    function _setDebtAllowedBatch(address[] memory _assets, bool _allow) internal {
        uint256 len = _assets.length;
        require(len < 11, TOO_MANY_ASSETS());
        if (len == 0) return;
        for (uint256 i; i < len; ++i) {
            address d = _assets[i];
            require(d != address(0), ZERO_ADDRESS());
            bool changed = _allow ? _debtAllowed.add(d) : _debtAllowed.remove(d);
            if (changed) emit DebtAssetAllowlisted(msg.sender, d, _allow);
        }
    }
}
