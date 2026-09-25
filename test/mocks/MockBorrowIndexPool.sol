// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IBorrowIndexProvider } from "src/labs/lending/interfaces/IBorrowIndexProvider.sol";

contract MockBorrowIndexPool is IBorrowIndexProvider {
    uint256 internal _index = 1e18;

    function setBorrowIndex(uint256 newIndex) external {
        _index = newIndex;
    }

    function currentBorrowIndex() external view returns (uint256) {
        return _index;
    }
}
