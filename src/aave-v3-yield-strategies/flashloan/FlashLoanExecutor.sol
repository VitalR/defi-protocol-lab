// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IFlashLoanSimpleReceiver } from "../interfaces/IFlashLoanSimpleReceiver.sol";
import { IPool, IPoolAddressesProvider } from "../interfaces/IAaveV3.sol";

/// @title FlashLoanExecutor (Aave V3 — Simple Flash Loan)
/// @notice Lightweight helper to initiate + settle an Aave V3 *simple* flash loan,
///         with an optional “real path” (e.g., DEX swap) executed via a generic target call.
/// @dev Keep this separate from your main strategy to minimize risk surface.
contract FlashLoanExecutor is IFlashLoanSimpleReceiver {
    /// @notice Aave V3 PoolAddressesProvider for the chosen market (e.g., Sepolia).
    IPoolAddressesProvider public immutable override ADDRESSES_PROVIDER;
    /// @notice Aave V3 Pool entrypoint for the chosen market.
    IPool public immutable override POOL;

    error EXTERNAL_CALL_FAILED();
    error NOT_POOL();
    error NOT_INITIATOR();
    error ZERO_AMOUNT();
    error ZERO_ADDRESS();

    /// @dev Optional params to execute during the flash loan.
    /// - feePayer: who will cover the fee (or any shortfall) by transferFrom to this contract.
    /// - target:   an optional contract to call (DEX/router/0x aggregator/etc).
    /// - data:     calldata for `target` (e.g., encoded swap call).
    /// - approveTarget: if true, this contract approves `target` to spend `asset` for `amount`.
    struct FlashParams {
        address feePayer;
        address target; // optional
        bytes data; // optional
        bool approveTarget; // optional
    }

    /// @param _provider Aave V3 PoolAddressesProvider for the chosen market (e.g., Sepolia).
    constructor(address _provider) {
        require(_provider != address(0), ZERO_ADDRESS());
        IPoolAddressesProvider provider = IPoolAddressesProvider(_provider);
        ADDRESSES_PROVIDER = provider;
        POOL = IPool(provider.getPool());
    }

    /// @notice Initiate a simple flash loan.
    /// @param _asset        Token to borrow.
    /// @param _amount       Amount to borrow (base units).
    /// @param _feePayer     Address that will cover the flash fee (and any shortfall).
    /// @param _target       (Optional) External contract to call during the loan (e.g., DEX router).
    /// @param _data         (Optional) Call data for `target` (already ABI-encoded).
    /// @param _approveTarget If true, approve `target` to spend `asset` for `amount` before the call.
    /// @param _referralCode Optional Aave referral code (0 if unused).
    function initiateFlashLoan(
        address _asset,
        uint256 _amount,
        address _feePayer,
        address _target,
        bytes calldata _data,
        bool _approveTarget,
        uint16 _referralCode
    ) external {
        if (_asset == address(0)) revert ZERO_ADDRESS();
        if (_amount == 0) revert ZERO_AMOUNT();

        bytes memory params = abi.encode(
            FlashParams({ feePayer: _feePayer, target: _target, data: _data, approveTarget: _approveTarget })
        );

        POOL.flashLoanSimple(address(this), _asset, _amount, params, _referralCode);
        // If we reach here, repayment succeeded; otherwise Aave reverted the tx.
    }

    /// @inheritdoc IFlashLoanSimpleReceiver
    function executeOperation(address _asset, uint256 _amount, uint256 _fee, address _initiator, bytes calldata _params)
        external
        override
        returns (bool)
    {
        // 1) Only Aave’s Pool can call this.
        require(msg.sender == address(POOL), NOT_POOL());

        // 2) The initiator must be this contract (we requested it).
        require(_initiator == address(this), NOT_INITIATOR());

        // 3) Decode params and (optionally) perform external logic.
        FlashParams memory p = abi.decode(_params, (FlashParams));

        if (p.target != address(0) && p.data.length > 0) {
            // (Optional) Approve target to spend the borrowed `asset`.
            if (p.approveTarget) {
                IERC20(_asset).approve(p.target, 0);
                IERC20(_asset).approve(p.target, _amount);
            }
            // Call the target (e.g., a DEX/aggregator swap).
            (bool ok, bytes memory ret) = p.target.call(p.data);
            if (!ok) revert EXTERNAL_CALL_FAILED();
            // If you expect a specific return shape, you can decode `ret` here.
            (ret);
        }

        // 4) Ensure we can repay principal + fee.
        uint256 totalOwed = _amount + _fee;
        uint256 bal = IERC20(_asset).balanceOf(address(this));
        if (bal < totalOwed) {
            // Pull the shortfall (typically just the fee) from feePayer.
            uint256 shortfall = totalOwed - bal;
            IERC20(_asset).transferFrom(p.feePayer, address(this), shortfall);
        }

        // 5) Approve Pool to pull back `amount + fee`.
        IERC20(_asset).approve(address(POOL), 0);
        IERC20(_asset).approve(address(POOL), totalOwed);

        // 6) Done.
        return true;
    }
}
