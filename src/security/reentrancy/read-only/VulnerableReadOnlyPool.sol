// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ReentrancyGuard } from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract VulnerableReadOnlyPool {
    mapping(address => uint256) public shares;
    uint256 public totalShares;

    function deposit() external payable {
        shares[msg.sender] += msg.value;
        totalShares += msg.value;
    }

    function pricePerShare() public view returns (uint256) {
        if (totalShares == 0) return 1e18;

        return address(this).balance * 1e18 / totalShares;
    }

    function withdraw(uint256 shareAmount) external {
        require(shares[msg.sender] >= shareAmount);

        uint256 assets = shareAmount * address(this).balance / totalShares;

        // INTERACTION BEFORE EFFECTS
        (bool success,) = payable(msg.sender).call{ value: assets }("");

        require(success);

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
    }
}

contract SafeReadOnlyPool {
    mapping(address => uint256) public shares;
    uint256 public totalShares;

    function deposit() external payable {
        shares[msg.sender] += msg.value;
        totalShares += msg.value;
    }

    function pricePerShare() public view returns (uint256) {
        if (totalShares == 0) return 1e18;

        return address(this).balance * 1e18 / totalShares;
    }

    function withdraw(uint256 shareAmount) external {
        require(shares[msg.sender] >= shareAmount);

        uint256 assets = shareAmount * address(this).balance / totalShares;

        // EFFECTS FIRST
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;

        // INTERACTION LAST
        (bool success,) = payable(msg.sender).call{ value: assets }("");

        require(success);
    }
}

contract SafeReentrancyGuardReadOnlyPool {
    error ReentrantCall();

    mapping(address => uint256) public shares;
    uint256 public totalShares;

    bool private lock;

    modifier nonReentrant() {
        if (lock) revert ReentrantCall();

        lock = true;
        _;
        lock = false;
    }

    modifier nonReentrantView() {
        if (lock) revert ReentrantCall();
        _;
    }

    function deposit() external payable {
        shares[msg.sender] += msg.value;
        totalShares += msg.value;
    }

    function pricePerShare() public view nonReentrantView returns (uint256) {
        if (totalShares == 0) return 1e18;

        return address(this).balance * 1e18 / totalShares;
    }

    function withdraw(uint256 shareAmount) external nonReentrant {
        require(shares[msg.sender] >= shareAmount);

        uint256 assets = shareAmount * address(this).balance / totalShares;

        // EFFECTS FIRST
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;

        // INTERACTION LAST
        (bool success,) = payable(msg.sender).call{ value: assets }("");

        require(success);
    }
}
