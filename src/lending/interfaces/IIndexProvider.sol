// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IIndexProvider {
    function currentBorrowIndex(address asset) external view returns (uint256);

    function currentLiquidityIndex(address asset) external view returns (uint256);
}
