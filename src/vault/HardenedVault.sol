// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Vault accounting requirements:
/// - Conversions use full-precision mulDiv and virtual asset/share liquidity.
/// - Deposit and redeem round down; mint and withdraw round up.
/// - Positive value-moving operations must not produce zero shares/assets.
/// - Deposit uses pre-transfer state and verifies the exact received asset delta.
/// - User entry points enforce operation-specific min/max slippage bounds.
/// - Shares are burned before external asset transfers; token calls are reentrancy-protected.
/// - Direct donations may change share price but must not make inflation attacks profitable.
/// - The supported asset must satisfy the documented transfer and rebase assumptions.
contract HardenedVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAmount();
    error ZeroShares();
    error SlippageExceeded();
    error InsupportedTokenBehaviour();
    error InsufficientShares();

    uint256 private constant VIRTUAL_ASSETS = 1;
    uint256 private constant VIRTUAL_SHARES = 1;

    IERC20 public immutable asset;

    uint256 public totalSupply;
    mapping(address account => uint256 shares) public balanceOf;

    constructor(IERC20 _asset) {
        asset = _asset;
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 _assets, Math.Rounding _rounding) public view returns (uint256 shares) {
        shares = Math.mulDiv(_assets, totalSupply + VIRTUAL_SHARES, totalAssets() + VIRTUAL_ASSETS, _rounding);
    }

    function convertToAssets(uint256 _shares, Math.Rounding _rounding) public view returns (uint256 assets) {
        assets = Math.mulDiv(_shares, totalAssets() + VIRTUAL_ASSETS, totalSupply + VIRTUAL_SHARES, _rounding);
    }

    function deposit(uint256 _assets, uint256 _minShares) external nonReentrant returns (uint256 shares) {
        require(_assets != 0, ZeroAmount());
        // require(_minShares != 0) revert ZeroShares();

        uint256 assetsBefore = totalAssets();

        // shares = supplyBefore == 0 ? _assets : Math.mulDiv(_assets, supplyBefore, assetsBefore, rounding.Floor);

        shares = convertToShares(_assets, Math.Rounding.Floor);
        if (shares == 0) revert ZeroShares();
        if (shares < _minShares) revert SlippageExceeded();

        asset.safeTransferFrom(msg.sender, address(this), _assets);

        uint256 assetsAfter = totalAssets();

        if (assetsAfter < assetsBefore || (assetsAfter - assetsBefore) != _assets) {
            revert InsupportedTokenBehaviour();
        }

        _mintShares(msg.sender, shares);
        // totalSupply += shares;
        // balanceOf[msg.sender] += shares;

        // emit Deposited event
    }

    function mint(uint256 _shares, uint256 _maxAssets) external nonReentrant returns (uint256 assets) {
        require(_shares > 0, ZeroShares());

        assets = convertToAssets(_shares, Math.Rounding.Ceil);

        if (assets == 0) revert ZeroAmount();
        if (assets > _maxAssets) revert SlippageExceeded();

        uint256 assetsBefore = totalAssets();

        asset.safeTransferFrom(msg.sender, address(this), assets);

        uint256 assetsAfter = totalAssets();

        if (assetsAfter < assetsBefore || assetsAfter - assetsBefore != assets) {
            revert InsupportedTokenBehaviour();
        }

        _mintShares(msg.sender, _shares);
    }

    function withdraw(uint256 _assets, uint256 _maxShares) external nonReentrant returns (uint256 shares) {
        require(_assets > 0, ZeroAmount());
        // require(_maxShares > 0, ZeroShares());

        shares = convertToShares(_assets, Math.Rounding.Ceil);

        if (shares == 0) revert ZeroShares();
        if (shares > _maxShares) revert SlippageExceeded();
        if (balanceOf[msg.sender] < shares) revert InsufficientShares();

        // balance[msg.sender] -= shares;
        // totalSupply -= shares;
        _burnShares(msg.sender, shares);

        asset.safeTransfer(msg.sender, _assets);

        // emit Withdrawn
    }

    function redeem(uint256 _shares, uint256 _minAssets) external nonReentrant returns (uint256 assets) {
        require(_shares > 0, ZeroAmount());
        require(balanceOf[msg.sender] >= _shares, InsufficientShares());

        assets = convertToAssets(_shares, Math.Rounding.Floor);

        if (assets == 0) revert ZeroAmount();
        if (assets < _minAssets) revert SlippageExceeded();

        _burnShares(msg.sender, _shares);

        asset.safeTransfer(msg.sender, assets);
    }

    function _mintShares(address _account, uint256 _shares) internal {
        totalSupply += _shares;
        balanceOf[_account] += _shares;
    }

    function _burnShares(address _account, uint256 _shares) internal {
        balanceOf[_account] -= _shares;
        totalSupply -= _shares;
    }
}
