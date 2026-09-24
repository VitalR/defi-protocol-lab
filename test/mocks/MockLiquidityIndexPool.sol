// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ILiquidityIndexProvider } from "src/labs/lending/interfaces/ILiquidityIndexProvider.sol";

contract MockLiquidityIndexPool is ILiquidityIndexProvider {
    uint256 internal _index = 1e18;

    function setLiquidityIndex(uint256 newIndex) external {
        _index = newIndex;
    }

    function currentLiquidityIndex() external view returns (uint256) {
        return _index;
    }
}
