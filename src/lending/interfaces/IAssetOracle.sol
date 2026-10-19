// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IAssetOracle {
    function collateralValueOf(address asset, uint256 amount)
        external
        view
        returns (uint256 valueWad, uint256 updatedAt);

    function debtValueOf(address asset, uint256 amount) external view returns (uint256 valueWad, uint256 updatedAt);

    function getAssetPrice(address asset) external view returns (uint256 priceWad, uint256 updatedAt);
}
