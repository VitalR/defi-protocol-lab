// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract MockFeeOnTransferERC20 is ERC20Mock, Ownable {
    uint256 public feeOnTransfer;

    constructor(address _owner, uint256 _feeOnTransfer) Ownable(_owner) {
        feeOnTransfer = _feeOnTransfer;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        address owner = _msgSender();
        uint256 valueSend = value - feeOnTransfer;
        _transfer(owner, to, valueSend);
        _transfer(owner, address(this), feeOnTransfer);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        uint256 valueSend = value - feeOnTransfer;
        _transfer(from, to, valueSend);
        _transfer(from, address(this), feeOnTransfer);
        return true;
    }

    function updateFeeOnTransfer(uint256 _feeOnTransfer) public onlyOwner {
        feeOnTransfer = _feeOnTransfer;
    }
}
