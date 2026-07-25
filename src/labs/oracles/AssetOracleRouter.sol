// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";
import { IPriceOracle } from "src/labs/oracles/PushOracleAdapter.sol";
import { OracleValuation } from "src/labs/oracles/OracleValuation.sol";

contract AssetOracleRouter is Ownable {
    error ZeroAmount();
    error ZeroAsset();
    error ZeroOracle();
    error UnsupportedTokenDecimals(uint8 decimals);
    error AssetNotConfigured(address asset);
    error AssetNotEnabled(address asset);
    error AssetAlreadyEnabled(address asset);
    error AssetAlreadyDisabled(address asset);
    error InvalidValueType();
    error InvalidIdentifier();
    error OracleBaseMismatch(bytes32 expected, bytes32 actual);
    error OracleQuoteMismatch(bytes32 expected, bytes32 actual);

    event AssetDisabled(address indexed asset);
    event AssetEnabled(address indexed asset);
    event OracleConfigUpdated(
        address indexed asset, address indexed previousOracle, address indexed newOracle, uint8 tokenDecimals
    );

    struct OracleConfig {
        IPriceOracle oracle;
        bytes32 baseIdentifier;
        uint8 tokenDecimals;
        bool enabled;
    }

    enum ValueType {
        Undefined,
        Collateral,
        Debt
    }

    bytes32 public constant QUOTE_IDENTIFIER = bytes32("USD");

    mapping(address asset => OracleConfig config) private _configs;

    constructor(address _owner) Ownable(_owner) { }

    function setOracleConfig(address asset, IPriceOracle oracle, bytes32 baseIdentifier, uint8 tokenDecimals)
        external
        onlyOwner
    {
        require(asset != address(0), ZeroAsset());
        require(address(oracle) != address(0), ZeroOracle());
        require(baseIdentifier != bytes32(0), InvalidIdentifier());

        if (tokenDecimals > DecimalMath.WAD_DECIMALS) revert UnsupportedTokenDecimals(tokenDecimals);

        bytes32 actualBase = oracle.baseIdentifier();
        require(actualBase == baseIdentifier, OracleBaseMismatch(baseIdentifier, actualBase));

        bytes32 actualQuote = oracle.quoteIdentifier();
        require(actualQuote == QUOTE_IDENTIFIER, OracleQuoteMismatch(QUOTE_IDENTIFIER, actualQuote));

        address previousOracle = address(_configs[asset].oracle);

        _configs[asset] = OracleConfig({
            oracle: oracle, baseIdentifier: baseIdentifier, tokenDecimals: tokenDecimals, enabled: true
        });

        emit OracleConfigUpdated(asset, previousOracle, address(_configs[asset].oracle), tokenDecimals);
    }

    function enableAsset(address asset) external onlyOwner {
        require(asset != address(0), ZeroAsset());

        OracleConfig storage config = _configs[asset];

        if (address(config.oracle) == address(0)) {
            revert AssetNotConfigured(asset);
        }

        if (config.enabled) {
            revert AssetAlreadyEnabled(asset);
        }

        config.enabled = true;

        emit AssetEnabled(asset);
    }

    function disableAsset(address asset) external onlyOwner {
        require(asset != address(0), ZeroAsset());

        OracleConfig storage config = _configs[asset];

        if (address(config.oracle) == address(0)) {
            revert AssetNotConfigured(asset);
        }

        if (!config.enabled) {
            revert AssetAlreadyDisabled(asset);
        }

        config.enabled = false;

        emit AssetDisabled(asset);
    }

    function getOracleConfig(address asset) external view returns (OracleConfig memory) {
        return _configs[asset];
    }

    function valueOf(address asset, uint256 amount, ValueType valueType)
        external
        view
        returns (uint256 valueWad, uint256 updatedAt)
    {
        require(asset != address(0), ZeroAsset());
        require(amount > 0, ZeroAmount());

        OracleConfig memory config = _getEnabledConfig(asset);

        Math.Rounding rounding;

        if (valueType == ValueType.Collateral) {
            rounding = Math.Rounding.Floor;
        } else if (valueType == ValueType.Debt) {
            rounding = Math.Rounding.Ceil;
        } else {
            revert InvalidValueType();
        }

        (uint256 priceWad, uint256 priceUpdatedAt) = config.oracle.latestPrice();

        valueWad = OracleValuation.valueInWad(amount, config.tokenDecimals, priceWad, rounding);

        updatedAt = priceUpdatedAt;
    }

    function collateralValueOf(address asset, uint256 amount)
        external
        view
        returns (uint256 valueWad, uint256 updatedAt)
    {
        require(asset != address(0), ZeroAsset());
        require(amount > 0, ZeroAmount());

        OracleConfig memory config = _getEnabledConfig(asset);

        (uint256 priceWad, uint256 priceUpdatedAt) = config.oracle.latestPrice();

        valueWad = OracleValuation.valueInWad(amount, config.tokenDecimals, priceWad, Math.Rounding.Floor);

        updatedAt = priceUpdatedAt;
    }

    function debtValueOf(address asset, uint256 amount) external view returns (uint256 valueWad, uint256 updatedAt) {
        require(asset != address(0), ZeroAsset());
        require(amount > 0, ZeroAmount());

        OracleConfig memory config = _getEnabledConfig(asset);

        (uint256 priceWad, uint256 priceUpdatedAt) = config.oracle.latestPrice();

        valueWad = OracleValuation.valueInWad(amount, config.tokenDecimals, priceWad, Math.Rounding.Ceil);

        updatedAt = priceUpdatedAt;
    }

    function _getEnabledConfig(address asset) internal view returns (OracleConfig memory config) {
        config = _configs[asset];

        if (address(config.oracle) == address(0)) {
            revert AssetNotConfigured(asset);
        }

        if (!config.enabled) {
            revert AssetNotEnabled(asset);
        }
    }
}
