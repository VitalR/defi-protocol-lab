// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPool, IPoolAddressesProvider } from "./IAaveV3.sol";

/// @title IFlashLoanSimpleReceiver (Aave V3)
/// @notice Minimum surface for a contract that can receive Aave V3 *simple* flash loans.
/// @dev The Pool calls `executeOperation` after sending the borrowed funds to the receiver.
///      The receiver must approve the Pool to pull back `amount + fee` before returning true.
interface IFlashLoanSimpleReceiver {
    /// @notice Market's Addresses Provider (resolves the Pool).
    function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider);

    /// @notice The Aave Pool for this market.
    function POOL() external view returns (IPool);

    /// @notice Callback invoked by Aave after sending the flash-loaned `asset`.
    /// @param asset      ERC-20 borrowed.
    /// @param amount     Principal borrowed.
    /// @param fee        Flash fee (“premium”) owed to the Pool.
    /// @param initiator  Address that initiated the flash loan (should be the receiver contract).
    /// @param params     Opaque bytes passed through from the initiator; use to configure your logic.
    /// @return success   Must return true if repayment (approval) is arranged; otherwise the tx reverts.
    function executeOperation(address asset, uint256 amount, uint256 fee, address initiator, bytes calldata params)
        external
        returns (bool);
}
