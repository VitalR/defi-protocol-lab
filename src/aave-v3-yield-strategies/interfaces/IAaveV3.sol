// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IAaveV3 Core Interfaces (minimal)
/// @notice Minimal surface used by integrations: Pool + PoolAddressesProvider.
/// @dev This is a minimal subset (stable across Aave V3 releases) suitable for supply/withdraw/borrow/repay.
///      If you need flash loans or data providers, extend here or import the canonical Aave interfaces.
interface IPool {
    /// @notice Supply an ERC-20 `asset` into the Aave Pool on behalf of `onBehalfOf`.
    /// @param asset The ERC-20 asset to supply.
    /// @param amount The amount to supply (units of `asset`).
    /// @param onBehalfOf The account that receives the aTokens and the credit.
    /// @param referralCode Optional referral code (0 if not used).
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Withdraw up to `amount` of `asset` to address `to`.
    /// @dev Use `type(uint256).max` to withdraw the full aToken balance.
    /// @return The actual amount withdrawn.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Enable or disable an asset as collateral for the caller.
    /// @param asset The supplied asset to toggle as collateral.
    /// @param useAsCollateral True to enable; false to disable.
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;

    /// @notice Borrow `asset` with selected interest mode on behalf of `onBehalfOf`.
    /// @param asset The ERC-20 debt asset to borrow.
    /// @param amount The amount to borrow.
    /// @param interestRateMode 1 = Stable (if enabled on market), 2 = Variable.
    /// @param referralCode Optional referral code (0 if not used).
    /// @param onBehalfOf The account that receives the debt.
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;

    /// @notice Repay an existing debt.
    /// @param asset The debt asset being repaid.
    /// @param amount The amount to repay (use `type(uint256).max` to repay all variable debt).
    /// @param interestRateMode 1 = Stable, 2 = Variable (must match the debt type).
    /// @param onBehalfOf The user whose debt is reduced.
    /// @return The actual repaid amount.
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);

    /// @notice Liquidates a position if the user’s health factor is below 1.
    /// @param collateralAsset The address of the underlying asset used as collateral, to be seized
    /// @param debtAsset       The address of the underlying borrowed asset being repaid
    /// @param user            The undercollateralized user’s address
    /// @param debtToCover     The amount of debt to repay (in debt asset units)
    /// @param receiveAToken   If true, the liquidator receives aTokens; if false, receives underlying collateral
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /// @notice Return account-level risk metrics (all values in base currency units unless noted).
    /// @param user The account to query.
    /// @return totalCollateralBase Total collateral value (base units)
    /// @return totalDebtBase Total debt value (base units)
    /// @return availableBorrowsBase Additional borrowable value (base units)
    /// @return currentLiquidationThreshold User threshold (bps, 10000 = 100%)
    /// @return ltv Loan-to-Value (bps)
    /// @return healthFactor Health factor (wad, 1e18 = 1.0)
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );

    /// @notice Initiates a simple flash loan and calls `executeOperation` on the receiver.
    /// @param receiverAddress The contract receiving the flash-borrowed amount (must implement
    /// IFlashLoanSimpleReceiver).
    /// @param asset           Address of the asset to be flash-borrowed.
    /// @param amount          Amount to borrow (base units).
    /// @param params          Opaque bytes forwarded to `executeOperation`.
    /// @param referralCode    Optional referral code (0 if unused).
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IPoolAddressesProvider {
    /// @notice Current Pool proxy address for this market.
    function getPool() external view returns (address);

    /// @notice Current Price Oracle proxy address for this market.
    function getPriceOracle() external view returns (address);
}

/// @notice Minimal Aave oracle surface.
interface IAaveOracle {
    /// @dev Price is in base currency units with 8 decimals (1e8 = 1.0 base currency, on Sepolia it's USD).
    function getAssetPrice(address asset) external view returns (uint256);
}
