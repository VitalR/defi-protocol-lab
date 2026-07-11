// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IAaveProtocolDataProvider (extended minimal)
/// @notice Minimal surface of Aave V3 ProtocolDataProvider used by our strategy + liquidation playground.
/// @dev Provides reserve token addresses and reserve configuration data for Aave markets.
/// @custom:seealso https://docs.aave.com/developers/core-contracts/protocol-dataprovider
interface IAaveProtocolDataProvider {
    /// @notice Convenience struct mirroring the triple of token addresses for a reserve.
    struct TokenData {
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
    }

    /// @notice Returns the token contract addresses associated with a reserve.
    /// @param asset The underlying ERC20 reserve address (e.g., WETH).
    /// @return aTokenAddress The interest-bearing aToken address for `asset`.
    /// @return stableDebtTokenAddress The stable debt token address for `asset` (may be zero address if disabled).
    /// @return variableDebtTokenAddress The variable debt token address for `asset`.
    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);

    /// @notice Returns the main configuration parameters of a reserve.
    /// @param asset The underlying ERC20 reserve address.
    /// @return ltv Loan-to-value ratio (bps, e.g. 8000 = 80%).
    /// @return liquidationThreshold Health factor threshold (bps) at which positions including this asset become
    /// liquidatable.
    /// @return liquidationBonus Bonus for liquidators, in basis points (e.g. 10500 = +5%).
    /// @return reserveDecimals Number of decimals of the underlying asset.
    /// @return reserveFactor Share of interest reserved for protocol treasury (bps).
    /// @return usageAsCollateralEnabled Whether the asset can be used as collateral.
    /// @return borrowingEnabled Whether the asset can be borrowed.
    /// @return stableBorrowRateEnabled Whether stable-rate borrowing is enabled.
    /// @return isActive Whether the reserve is active.
    /// @return isFrozen Whether the reserve is frozen.
    function getReserveConfigurationData(address asset)
        external
        view
        returns (
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveDecimals,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        );
}
