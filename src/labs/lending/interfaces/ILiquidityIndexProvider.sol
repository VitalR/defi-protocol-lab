// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface ILiquidityIndexProvider {
    function currentLiquidityIndex() external view returns (uint256);
}
