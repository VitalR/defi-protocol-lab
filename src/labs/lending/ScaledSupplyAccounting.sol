// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract ScaledSupplyAccounting {
    error ZeroAmount();
    error InvalidIndex(uint256 index);
    error IndexCannotDecrease(uint256 currentIndex, uint256 newIndex);
    error SupplyTooSmall(uint256 amount);
    error WithdrawExceedsSupply(uint256 amount, uint256 currentSupply);

    uint256 internal constant WAD = 1e18;

    uint256 public liquidityIndex;
    uint256 public totalScaledSupply;

    mapping(address => uint256) internal _scaledSupply;

    constructor() {
        liquidityIndex = WAD;
    }

    function supply(address user, uint256 amount) external {
        require(amount > 0, ZeroAmount());

        uint256 scaledMint = Math.mulDiv(amount, WAD, liquidityIndex, Math.Rounding.Floor);

        require(scaledMint > 0, SupplyTooSmall(amount));

        _scaledSupply[user] += scaledMint;
        totalScaledSupply += scaledMint;
    }

    function withdraw(address user, uint256 amount) external {
        require(amount > 0, ZeroAmount());

        uint256 currentSupply = supplyOf(user);

        require(amount <= currentSupply, WithdrawExceedsSupply(amount, currentSupply));

        uint256 scaledSupply = _scaledSupply[user];
        if (amount == currentSupply) {
            _scaledSupply[user] = 0;
            totalScaledSupply -= scaledSupply;
            return;
        }

        uint256 scaledBurn = Math.mulDiv(amount, WAD, liquidityIndex, Math.Rounding.Ceil);

        _scaledSupply[user] -= scaledBurn;
        totalScaledSupply -= scaledBurn;
    }

    function setLiquidityIndex(uint256 newIndex) external {
        require(newIndex >= WAD, InvalidIndex(newIndex));
        require(newIndex >= liquidityIndex, IndexCannotDecrease(liquidityIndex, newIndex));

        liquidityIndex = newIndex;
    }

    function scaledSupplyOf(address user) external view returns (uint256) {
        return _scaledSupply[user];
    }

    function supplyOf(address user) public view returns (uint256) {
        return Math.mulDiv(_scaledSupply[user], liquidityIndex, WAD, Math.Rounding.Floor);
    }

    function totalSupply() external view returns (uint256) {
        return Math.mulDiv(totalScaledSupply, liquidityIndex, WAD, Math.Rounding.Floor);
    }
}
