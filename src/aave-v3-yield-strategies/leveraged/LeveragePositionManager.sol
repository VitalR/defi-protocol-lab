// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IPool } from "src/aave-v3-yield-strategies/interfaces/IAaveV3.sol";
import { IAaveProtocolDataProvider } from "src/aave-v3-yield-strategies/interfaces/IAaveProtocolDataProvider.sol";
import { IUniswapV3RouterExactInputSingle } from
    "src/aave-v3-yield-strategies/interfaces/IUniswapV3RouterExactInputSingle.sol";
import { TokenActions } from "src/aave-v3-yield-strategies/libs/TokenActions.sol";

/// @title LeveragePositionManager (Aave V3 + Uniswap V3)
/// @notice A production-friendly helper to open/close leveraged long/short positions on Aave V3 using Uniswap V3 swaps.
/// @dev
/// - Non-custodial per-user: all Aave actions use `onBehalfOf = msg.sender`
/// - OPEN flow:
///     * Pull collateral from user (fee-on-transfer safe via TokenActions)
///     * Supply collateral to Aave (on behalf of user)
///     * Borrow debt asset (variable rate, mode=2) on behalf of user
///     * Swap borrowed -> collateral on Uniswap V3
///     * Optionally re-supply swapped collateral back into Aave for the user
/// - CLOSE flow:
///     * Pull aTokens from user (aToken transfer to this contract)
///     * Withdraw underlying collateral from Aave to this contract
///     * Swap collateral -> debt on Uniswap V3
///     * Repay user’s variable debt, topping-up from user if swap output is insufficient
///     * Send any debt-token leftover (profit/excess) to user
/// - Pool/Data resolved in constructor (upgrade-safe to Pool impl changes)
/// - Uses `IAaveProtocolDataProvider` to discover aToken / variable-debt token addresses
/// - Uses project `TokenActions` for fee-on-transfer safety and USDT-style force approvals
contract LeveragePositionManager is ReentrancyGuard {
    using TokenActions for IERC20;

    // =============================================================
    //                 CONFIGURATION & STORAGE
    // =============================================================

    /// @notice Aave V3 Pool entrypoint.
    IPool public immutable pool;

    /// @notice Aave V3 ProtocolDataProvider for token discovery.
    IAaveProtocolDataProvider public immutable dataProvider;

    /// @notice Uniswap V3 router (supports `exactInputSingle`).
    IUniswapV3RouterExactInputSingle public immutable uni;

    // =============================================================
    //                      EVENTS & ERRORS
    // =============================================================

    /// @notice Emitted when a position is opened.
    /// @param user The EOA for whom the position is managed (also the payer/beneficiary).
    /// @param collateral The collateral asset supplied to Aave.
    /// @param collateralSupplied The amount of collateral initially supplied to Aave.
    /// @param debt The debt asset borrowed from Aave.
    /// @param debtAmount The amount of debt borrowed (pre-swap).
    /// @param swappedToCollateral The amount of collateral received from the borrow->collateral swap.
    /// @param resupplied True if `swappedToCollateral` was re-supplied to Aave for the user.
    /// @param hfAfter The user’s Health Factor after the full open flow has completed.
    event Opened(
        address indexed user,
        address indexed collateral,
        uint256 collateralSupplied,
        address indexed debt,
        uint256 debtAmount,
        uint256 swappedToCollateral,
        bool resupplied,
        uint256 hfAfter
    );

    /// @notice Emitted when a position is closed (partially or fully).
    /// @param user The EOA whose position is being closed.
    /// @param collateral The collateral asset withdrawn from Aave.
    /// @param aTokensPulled The amount of aTokens pulled from `user` into this contract.
    /// @param collateralWithdrawn The amount of underlying collateral withdrawn from Aave to this contract.
    /// @param debt The debt asset repaid.
    /// @param repaidTotal Total amount repaid to Aave for the user (swap output + any top-up from user).
    /// @param repaidFromUser Portion of `repaidTotal` that was pulled from user due to swap shortfall.
    /// @param leftoverDebtTokens Any debt-token remainder after repay that was forwarded to the user (profit/excess).
    event Closed(
        address indexed user,
        address indexed collateral,
        uint256 aTokensPulled,
        uint256 collateralWithdrawn,
        address indexed debt,
        uint256 repaidTotal,
        uint256 repaidFromUser,
        uint256 leftoverDebtTokens
    );

    /// @notice Thrown when the requested minimum Health Factor constraint is not met.
    error BAD_MIN_HEALTH_FACTOR();

    /// @notice Thrown when a swap fails or returns zero output.
    error SWAP_FAILED();

    /// @notice Thrown when a zero address is passed where a non-zero address is required.
    error ZERO_ADDRESS();

    /// @notice Thrown when a zero amount is passed where a positive value is required.
    error ZERO_AMOUNT();

    // =============================================================
    //                          PARAMS
    // =============================================================

    /// @notice Parameters for opening a leveraged position.
    /// @dev `onBehalfOf` is always `msg.sender` by design (non-custodial per-user).
    struct OpenParams {
        address collateralToken; // e.g., WETH
        uint256 collateralAmount; // amount user supplies
        address borrowToken; // e.g., USDC
        uint256 borrowAmount; // amount to borrow (variable rate)
        uint16 referralCode; // Aave referral (0 if unused)
        uint24 uniFee; // Uniswap V3 fee tier (500/3000/10000)
        uint256 minOut; // min amountOut for borrow->coll swap
        uint256 deadline; // swap deadline (unix)
        uint256 minHealthFactor; // require HF >= this (1e18 = 1.0) after borrow
        bool resupplySwapped; // if true, re-supply swapped collateral back to Aave on behalf of user
    }

    /// @notice Parameters for closing a leveraged position.
    /// @dev `onBehalfOf` is always `msg.sender`. aTokens are pulled from the user to this contract.
    struct CloseParams {
        address collateralToken; // e.g., WETH
        address borrowToken; // e.g., USDC
        uint256 aTokensToPull; // aTokens to pull from user (use type(uint256).max for all)
        uint256 withdrawAmount; // underlying to withdraw (use type(uint256).max for all)
        uint24 uniFee; // Uniswap V3 fee tier
        uint256 minOut; // min amountOut for coll->debt swap
        uint256 deadline; // swap deadline (unix)
        uint256 maxDebtToRepay; // cap repay amount (0 => repay full current variable debt)
    }

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    /// @notice Initialize leverage manager with Aave and Uniswap endpoints.
    /// @param _pool Aave V3 Pool.
    /// @param _data Aave V3 ProtocolDataProvider.
    /// @param _uni  Uniswap V3 router (exactInputSingle).
    constructor(address _pool, address _data, address _uni) {
        if (_pool == address(0) || _data == address(0) || _uni == address(0)) revert ZERO_ADDRESS();
        pool = IPool(_pool);
        dataProvider = IAaveProtocolDataProvider(_data);
        uni = IUniswapV3RouterExactInputSingle(_uni);
    }

    // =============================================================
    //                          USER ACTIONS
    // =============================================================

    /// @notice Open a leveraged position: supply collateral, borrow debt, swap debt→collateral, optionally re-supply.
    /// @dev All Aave operations are performed with `onBehalfOf = msg.sender`.
    /// @param p The {OpenParams} payload describing assets, amounts and swap details.
    /// @return collateralAmountOut Amount of collateral received from the borrow→collateral swap (this same amount is
    ///         also supplied to Aave if `p.resupplySwapped` is true).
    function open(OpenParams calldata p) external nonReentrant returns (uint256 collateralAmountOut) {
        if (p.minHealthFactor <= 1e18) revert BAD_MIN_HEALTH_FACTOR();
        if (p.collateralAmount == 0 || p.borrowAmount == 0) revert ZERO_AMOUNT();

        // 1) Pull collateral from user and supply to Aave on behalf of user.
        uint256 received = IERC20(p.collateralToken).pullFrom(msg.sender, p.collateralAmount);
        if (received == 0) revert ZERO_AMOUNT();
        IERC20(p.collateralToken).approveExact(address(pool), received);
        pool.supply(p.collateralToken, received, msg.sender, p.referralCode);

        // 2) Borrow debt on behalf of user (variable 2).
        pool.borrow(p.borrowToken, p.borrowAmount, 2, p.referralCode, msg.sender);

        // 3) HF guard post-borrow
        (,,,,, uint256 hfAfterBorrow) = pool.getUserAccountData(msg.sender);
        if (hfAfterBorrow < p.minHealthFactor) revert BAD_MIN_HEALTH_FACTOR();

        // 4) Swap borrowed -> collateral.
        //    Pull *from user* (they hold the borrowed tokens), swap to collateral.
        uint256 pulledDebt = IERC20(p.borrowToken).pullFrom(msg.sender, p.borrowAmount);
        IERC20(p.borrowToken).approveExact(address(uni), pulledDebt);

        address recipient = p.resupplySwapped ? address(this) : msg.sender;
        collateralAmountOut = uni.exactInputSingle(
            IUniswapV3RouterExactInputSingle.ExactInputSingleParams({
                tokenIn: p.borrowToken,
                tokenOut: p.collateralToken,
                fee: p.uniFee,
                recipient: recipient,
                deadline: p.deadline,
                amountIn: pulledDebt,
                amountOutMinimum: p.minOut,
                sqrtPriceLimitX96: 0
            })
        );
        if (collateralAmountOut == 0) revert SWAP_FAILED();

        // 5) Optional re-supply swapped collateral.
        bool resupplied = false;
        uint256 hfAfter = hfAfterBorrow;
        if (p.resupplySwapped) {
            IERC20(p.collateralToken).approveExact(address(pool), collateralAmountOut);
            pool.supply(p.collateralToken, collateralAmountOut, msg.sender, p.referralCode);
            resupplied = true;
            (,,,,, hfAfter) = pool.getUserAccountData(msg.sender);
        }

        emit Opened(
            msg.sender,
            p.collateralToken,
            received,
            p.borrowToken,
            p.borrowAmount,
            collateralAmountOut,
            resupplied,
            hfAfter
        );
    }

    /// @notice Close part/all of a leveraged position by withdrawing collateral, swapping to debt, and repaying.
    /// @dev Pulls aTokens from the user, withdraws underlying to this contract, swaps collateral→debt, repays user’s
    ///      variable debt (topping up from user if needed), then forwards any leftover debt tokens to the user.
    /// @param p The {CloseParams} payload describing assets, amounts and swap details.
    /// @return collateralWithdrawn Amount of collateral withdrawn from Aave.
    /// @return debtRepaidFromMsgSender Extra debt tokens pulled from user to complete repay (if swap insufficient).
    /// @return leftoverDebtTokens Debt token remainder after repay (sent to user).
    function close(CloseParams calldata p)
        external
        nonReentrant
        returns (uint256 collateralWithdrawn, uint256 debtRepaidFromMsgSender, uint256 leftoverDebtTokens)
    {
        // 1) Pull aTokens from user and withdraw underlying to this contract.
        (uint256 toPullATokens, uint256 withdrawn) =
            _pullATokensAndWithdraw(p.collateralToken, p.aTokensToPull, p.withdrawAmount);
        collateralWithdrawn = withdrawn;

        // 2) Swap collateral -> debt.
        uint256 swappedToDebt = _swapCollateralForDebt(
            p.collateralToken, p.borrowToken, p.uniFee, collateralWithdrawn, p.minOut, p.deadline
        );

        // 3) Repay variable debt for user (cap by maxDebtToRepay).
        (uint256 repaidTotal, uint256 repaidFromUser) = _repayWithCap(p.borrowToken, swappedToDebt, p.maxDebtToRepay);
        debtRepaidFromMsgSender = repaidFromUser;

        // 4) Send any leftover debt tokens (profit/excess) to the user.
        leftoverDebtTokens = _transferLeftoverDebt(p.borrowToken);

        emit Closed(
            msg.sender,
            p.collateralToken,
            toPullATokens,
            collateralWithdrawn,
            p.borrowToken,
            repaidTotal,
            debtRepaidFromMsgSender,
            leftoverDebtTokens
        );
    }

    // =============================================================
    //                          INTERNAL
    // =============================================================

    /// @notice Pull `aTokensToPull` aTokens from user and withdraw `withdrawAmount` underlying to this contract.
    /// @dev Use `type(uint256).max` to pull/withdraw the full balance.
    /// @param collateralToken The underlying collateral asset.
    /// @param aTokensToPull Amount of aTokens to pull from user (use MAX for all).
    /// @param withdrawAmount Amount of underlying to withdraw from Aave (use MAX for all).
    /// @return toPullATokens Actual aTokens pulled from the user.
    /// @return collateralWithdrawn Actual underlying withdrawn to this contract.
    function _pullATokensAndWithdraw(address collateralToken, uint256 aTokensToPull, uint256 withdrawAmount)
        private
        returns (uint256 toPullATokens, uint256 collateralWithdrawn)
    {
        address aToken = _aTokenOf(collateralToken);
        toPullATokens = aTokensToPull == type(uint256).max ? IERC20(aToken).balanceOf(msg.sender) : aTokensToPull;
        if (toPullATokens == 0) revert ZERO_AMOUNT();
        IERC20(aToken).pullFrom(msg.sender, toPullATokens);

        uint256 toWithdraw = withdrawAmount == type(uint256).max ? type(uint256).max : withdrawAmount;
        collateralWithdrawn = pool.withdraw(collateralToken, toWithdraw, address(this));
    }

    /// @notice Swap `amountIn` of `collateralToken` to `borrowToken` via Uniswap V3.
    /// @dev Approves router exactly for `amountIn`. Reverts with SWAP_FAILED on zero output.
    /// @param collateralToken The token to sell.
    /// @param borrowToken The token to receive (debt asset).
    /// @param uniFee Uniswap pool fee tier.
    /// @param amountIn Input amount of collateral to swap.
    /// @param minOut Minimum acceptable output to protect against slippage.
    /// @param deadline Swap deadline (unix timestamp).
    /// @return amountOut Amount of `borrowToken` received.
    function _swapCollateralForDebt(
        address collateralToken,
        address borrowToken,
        uint24 uniFee,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline
    ) private returns (uint256 amountOut) {
        IERC20(collateralToken).approveExact(address(uni), amountIn);
        amountOut = uni.exactInputSingle(
            IUniswapV3RouterExactInputSingle.ExactInputSingleParams({
                tokenIn: collateralToken,
                tokenOut: borrowToken,
                fee: uniFee,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        if (amountOut == 0) revert SWAP_FAILED();
    }

    /// @notice Repay user’s variable-rate debt using swap output, topping up from user if capped amount exceeds output.
    /// @dev Caps repayment by `maxDebtToRepay` (0 => repay full current variable debt).
    /// @param borrowToken Debt token to repay.
    /// @param swappedAmount Amount of `borrowToken` available from the swap.
    /// @param maxDebtToRepay Repay cap (0 => full current debt).
    /// @return repaidTotal Total repaid (swap output + any user top-up).
    /// @return repaidFromUser Portion pulled from the user to cover shortfall (if any).
    function _repayWithCap(address borrowToken, uint256 swappedAmount, uint256 maxDebtToRepay)
        private
        returns (uint256 repaidTotal, uint256 repaidFromUser)
    {
        uint256 currentDebt = _variableDebtOf(borrowToken, msg.sender);
        uint256 repayCap = (maxDebtToRepay == 0) ? currentDebt : Math.min(currentDebt, maxDebtToRepay);

        repaidTotal = swappedAmount > repayCap ? repayCap : swappedAmount;
        if (repaidTotal < repayCap) {
            unchecked {
                uint256 shortfall = repayCap - repaidTotal;
                repaidFromUser = IERC20(borrowToken).pullFrom(msg.sender, shortfall);
                repaidTotal += repaidFromUser;
            }
        }

        if (repaidTotal > 0) {
            IERC20(borrowToken).approveExact(address(pool), repaidTotal);
            pool.repay(borrowToken, repaidTotal, 2, msg.sender);
        }
    }

    /// @notice Forward any leftover debt tokens (profit/excess) held by this contract back to the user.
    /// @param borrowToken Debt token address.
    /// @return leftover Amount of `borrowToken` sent to the user.
    function _transferLeftoverDebt(address borrowToken) private returns (uint256 leftover) {
        leftover = IERC20(borrowToken).balanceOf(address(this));
        if (leftover > 0) {
            // No need to leave any allowance here; just transfer out to user.
            IERC20(borrowToken).transfer(msg.sender, leftover);
        }
    }

    // =============================================================
    //                          VIEWS
    // =============================================================

    /// @notice Return aToken address for an underlying asset via Aave ProtocolDataProvider.
    /// @param asset Underlying asset address.
    /// @return aToken The aToken address for `asset`.
    function _aTokenOf(address asset) public view returns (address aToken) {
        (aToken,,) = dataProvider.getReserveTokensAddresses(asset);
    }

    /// @notice Return user’s variable debt balance for an underlying asset.
    /// @param asset Underlying asset (its variable debt token will be read via data provider).
    /// @param user The Aave user to query.
    /// @return The variable debt balance of `user` for `asset`.
    function _variableDebtOf(address asset, address user) public view returns (uint256) {
        (,, address vDebt) = dataProvider.getReserveTokensAddresses(asset);
        return IERC20(vDebt).balanceOf(user);
    }
}
