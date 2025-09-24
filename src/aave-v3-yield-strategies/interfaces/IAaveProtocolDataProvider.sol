// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IAaveProtocolDataProvider (minimal)
/// @notice Minimal surface of Aave V3 ProtocolDataProvider used by the strategy for reserve token discovery.
/// @dev On Aave V3, each listed underlying reserve has:
///      - an aToken (interest-bearing token representing supplied balance)
///      - a stable debt token (optional; not used by this strategy)
///      - a variable debt token (used if the user borrows at variable rate)
///      This interface only exposes the function needed to fetch those token addresses.
///
/// @custom:seealso Aave docs: https://docs.aave.com/
interface IAaveProtocolDataProvider {
    /// @notice Convenience struct mirroring the triple of token addresses for a reserve.
    /// @dev Not returned by functions in this minimal surface; included for clarity.
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
}
