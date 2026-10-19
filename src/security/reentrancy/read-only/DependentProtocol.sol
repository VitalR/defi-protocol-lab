// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IPricePool {
    function pricePerShare() external view returns (uint256);
}

contract DependentProtocol {
    IPricePool public immutable pool;

    uint256 public lastPrice;

    constructor(address pool_) {
        pool = IPricePool(pool_);
    }

    function snapshotPrice() external {
        lastPrice = pool.pricePerShare();
    }
}
