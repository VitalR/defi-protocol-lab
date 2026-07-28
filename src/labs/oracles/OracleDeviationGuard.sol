// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IPriceOracle } from "src/labs/oracles/interfaces/IPriceOracle.sol";

contract OracleDeviationGuard is IPriceOracle {
    error ZeroPrimaryOracle();
    error ZeroReferenceOracle();
    error SameOracle();
    error InvalidMaxDeviationBps(uint256 maxDeviationBps);
    error OracleBaseMismatch(bytes32 primaryBase, bytes32 referenceBase);
    error OracleQuoteMismatch(bytes32 primaryQuote, bytes32 referenceQuote);
    error PriceDeviationExceeded(
        uint256 primaryPrice, uint256 referencePrice, uint256 deviationBps, uint256 maxDeviationBps
    );
    error InvalidReferencePrice();

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_DEVIATION_BPS = 5000;

    IPriceOracle public immutable primaryOracle;
    IPriceOracle public immutable referenceOracle;
    uint256 public immutable maxDeviationBps;

    constructor(IPriceOracle _primaryOracle, IPriceOracle _referenceOracle, uint256 _maxDeviationBps) {
        require(address(_primaryOracle) != address(0), ZeroPrimaryOracle());
        require(address(_referenceOracle) != address(0), ZeroReferenceOracle());
        require(address(_primaryOracle) != address(_referenceOracle), SameOracle());
        require(_maxDeviationBps > 0 && _maxDeviationBps <= MAX_DEVIATION_BPS, InvalidMaxDeviationBps(_maxDeviationBps));

        bytes32 primaryBase = _primaryOracle.baseIdentifier();
        bytes32 referenceBase = _referenceOracle.baseIdentifier();
        require(primaryBase == referenceBase, OracleBaseMismatch(primaryBase, referenceBase));

        bytes32 primaryQuote = _primaryOracle.quoteIdentifier();
        bytes32 referenceQuote = _referenceOracle.quoteIdentifier();
        require(primaryQuote == referenceQuote, OracleQuoteMismatch(primaryQuote, referenceQuote));

        primaryOracle = _primaryOracle;
        referenceOracle = _referenceOracle;
        maxDeviationBps = _maxDeviationBps;
    }

    function latestPrice() external view returns (uint256 priceWad, uint256 updatedAt) {
        (uint256 primaryPrice, uint256 primaryUpdatedAt) = primaryOracle.latestPrice();

        (uint256 referencePrice, uint256 referenceUpdatedAt) = referenceOracle.latestPrice();
        require(referencePrice > 0, InvalidReferencePrice());

        uint256 difference =
            primaryPrice > referencePrice ? primaryPrice - referencePrice : referencePrice - primaryPrice;

        uint256 deviationBps = Math.mulDiv(difference, BPS_DENOMINATOR, referencePrice, Math.Rounding.Ceil);

        if (deviationBps > maxDeviationBps) {
            revert PriceDeviationExceeded(primaryPrice, referencePrice, deviationBps, maxDeviationBps);
        }

        return (primaryPrice, Math.min(primaryUpdatedAt, referenceUpdatedAt));
    }

    function baseIdentifier() external view returns (bytes32) {
        return primaryOracle.baseIdentifier();
    }

    function quoteIdentifier() external view returns (bytes32) {
        return primaryOracle.quoteIdentifier();
    }
}
