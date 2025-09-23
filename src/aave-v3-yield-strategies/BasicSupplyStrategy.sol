// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IPool, IPoolAddressesProvider } from "./interfaces/IAaveV3.sol";

contract BasicSupplyStrategy {
    using SafeERC20 for IERC20;

    IPool public immutable pool;
    address public immutable asset; // e.g., USDC on the chosen market

    constructor(address _provider, address _asset) {
        pool = IPool(IPoolAddressesProvider(_provider).getPool());
        asset = _asset;
    }

    function supplyMax(uint16 referralCode) external {
        uint256 bal = IERC20(asset).balanceOf(msg.sender);
        require(bal > 0, "NO_FUNDS");

        // pull funds
        IERC20(asset).safeTransferFrom(msg.sender, address(this), bal);

        // OZ v5: use forceApprove instead of safeApprove
        IERC20(asset).forceApprove(address(pool), 0);
        IERC20(asset).forceApprove(address(pool), bal);

        // supply on behalf of the caller so they receive aTokens directly
        pool.supply(asset, bal, msg.sender, referralCode);
    }

    function enableCollateral() external {
        pool.setUserUseReserveAsCollateral(asset, true);
    }

    function withdrawAll() external {
        // type(uint256).max withdraws the full aToken balance for msg.sender
        pool.withdraw(asset, type(uint256).max, msg.sender);
    }

    // Next level: borrow/repay (variable rate = 2)
    function borrowVariable(address debtAsset, uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");
        pool.borrow(debtAsset, amount, 2, 0, msg.sender);
    }

    function repayVariable(address debtAsset, uint256 amount) external {
        require(amount > 0, "ZERO_AMOUNT");

        // pull repayment funds
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), amount);

        // approve pool to pull repayment
        IERC20(debtAsset).forceApprove(address(pool), 0);
        IERC20(debtAsset).forceApprove(address(pool), amount);

        pool.repay(debtAsset, amount, 2, msg.sender);
    }

    function healthFactor(address user) external view returns (uint256 hf) {
        (, , , , , hf) = pool.getUserAccountData(user);
    }
}
