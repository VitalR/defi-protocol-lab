// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract SafeRoyaltyRegistry is Ownable {
    error UnauthorizedClaim();

    uint256 constant regularPayout = 0.1 ether;
    uint256 constant premiumPayout = 1 ether;

    mapping(bytes32 => bool) internal _allowedPayouts;

    constructor(address admin) Ownable(admin) { }

    function registerAllowedPayouts(address[] calldata privileged, address[] calldata regular) external onlyOwner {
        bytes32 payoutKey = keccak256(abi.encode(privileged, regular));

        _allowedPayouts[payoutKey] = true;
    }

    function claimRewards(address[] calldata privileged, address[] calldata regular) external {
        // @audit two variable-length arrays packed side by side
        bytes32 payoutKey = keccak256(abi.encode(privileged, regular));

        require(_allowedPayouts[payoutKey], UnauthorizedClaim());

        _allowedPayouts[payoutKey] = false;

        _payout(privileged, premiumPayout);
        _payout(regular, regularPayout);
    }

    function _payout(address[] calldata users, uint256 reward) internal {
        for (uint256 i = 0; i < users.length;) {
            (bool success,) = users[i].call{ value: reward }("");
            if (!success) {
                // more code handling pull payment
            }
            unchecked {
                ++i;
            }
        }
    }
}
