// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IBorrowIndexProvider {
    function currentBorrowIndex() external view returns (uint256);
}
