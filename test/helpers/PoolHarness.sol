// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Pool } from "src/lending/Pool.sol";
import { DecimalMath } from "src/common/math/DecimalMath.sol";

contract PoolHarness is Pool {
    constructor(address provider) Pool(provider) { }

    function setLiquidityIndexForTest(address asset, uint256 index) external {
        require(index >= DecimalMath.WAD);

        _getInitializedReserve(asset).state.liquidityIndex = index;
    }
}
