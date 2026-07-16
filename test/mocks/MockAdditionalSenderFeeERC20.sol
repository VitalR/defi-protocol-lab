// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockAdditionalSenderFeeERC20 is ERC20 {
    uint256 public immutable fee;
    address public immutable feeRecipient;

    constructor(address _feeRecipient, uint256 _fee) ERC20("Additional Sender Fee Token", "ASFT") {
        feeRecipient = _feeRecipient;
        fee = _fee;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Minting and burning should not pay a transfer fee.
        if (from == address(0) || to == address(0) || fee == 0) {
            super._update(from, to, value);
            return;
        }

        // Recipient receives the full requested value.
        super._update(from, to, value);

        // Sender pays an additional fee.
        super._update(from, feeRecipient, fee);
    }
}
