// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { DecimalMath } from "src/common/math/DecimalMath.sol";
import { TokenTransfer } from "src/common/token/TokenTransfer.sol";
import { OracleDeviationGuard, IPriceOracle } from "src/labs/oracles/OracleDeviationGuard.sol";

contract SimpleLendingPool {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();

    event Supplied(address indexed user, address indexed collateralToken, uint256 amount);

    IERC20 public immutable collateralToken; // WETH
    IERC20 public immutable debtToken; // USDC

    IPriceOracle public immutable oracle;

    uint256 public constant LTV = 7500; // 75%
    uint256 public constant LIQUIDATION_THRESHOLD = 8000; // 80%

    mapping(address user => uint256 amount) private _collateralBalance;
    mapping(address user => uint256 amount) private _debtBalance;

    constructor(address _collateralToken, address _debtToken, address _oracle) {
        require(_collateralToken != address(0) && _debtToken != address(0) && _oracle != address(0), ZeroAddress());

        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        oracle = IPriceOracle(_oracle);
    }

    function supplyCollateral(uint256 amount) external {
        require(amount > 0, ZeroAmount());

        TokenTransfer.pullExact(collateralToken, msg.sender, amount);

        _collateralBalance[msg.sender] += amount;

        emit Supplied(msg.sender, address(collateralToken), amount);
    }

    function collateralOf(address user) external view returns (uint256) {
        return _collateralBalance[user];
    }
}
