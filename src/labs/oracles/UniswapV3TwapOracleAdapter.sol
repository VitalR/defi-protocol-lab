// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IPriceOracle } from "src/labs/oracles/interfaces/IPriceOracle.sol";
import { IUniswapV3PoolOracle } from "src/labs/oracles/interfaces/IUniswapV3PoolOracle.sol";
import { UniswapV3OracleMath } from "src/labs/oracles/libraries/UniswapV3OracleMath.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";

contract UniswapV3TwapOracleAdapter is IPriceOracle {
    error ZeroPool();
    error ZeroBaseToken();
    error ZeroQuoteToken();
    error SameToken();
    error InvalidPair(bytes32 base, bytes32 quote);
    error ZeroTwapWindow();
    error ZeroMaxObservationStaleness();

    error PoolTokenMismatch(address poolToken0, address poolToken1, address baseToken, address quoteToken);
    error UnsupportedTokenDecimals(address token, uint8 decimals);

    error UninitializedObservation(uint16 observationIndex);
    error StaleObservation(uint256 updatedAt, uint256 currentTimestamp, uint256 maxObservationStaleness);
    error InvalidPrice();

    IUniswapV3PoolOracle public immutable pool;

    address public immutable baseToken;
    address public immutable quoteToken;

    uint8 public immutable baseTokenDecimals;
    uint8 public immutable quoteTokenDecimals;

    bytes32 public immutable baseIdentifier;
    bytes32 public immutable quoteIdentifier;

    uint32 public immutable twapWindow;
    uint32 public immutable maxObservationStaleness;

    constructor(
        address _pool,
        address _baseToken,
        address _quoteToken,
        bytes32 _baseIdentifier,
        bytes32 _quoteIdentifier,
        uint32 _twapWindow,
        uint32 _maxObservationStaleness
    ) {
        require(_pool != address(0), ZeroPool());
        require(_baseToken != address(0), ZeroBaseToken());
        require(_quoteToken != address(0), ZeroQuoteToken());
        require(_baseToken != _quoteToken, SameToken());
        if (_baseIdentifier == bytes32(0) || _quoteIdentifier == bytes32(0) || _baseIdentifier == _quoteIdentifier) {
            revert InvalidPair(_baseIdentifier, _quoteIdentifier);
        }
        require(_twapWindow != 0, ZeroTwapWindow());
        require(_maxObservationStaleness != 0, ZeroMaxObservationStaleness());

        pool = IUniswapV3PoolOracle(_pool);
        address poolToken0 = pool.token0();
        address poolToken1 = pool.token1();

        bool directPair = poolToken0 == _baseToken && poolToken1 == _quoteToken;
        bool inversePair = poolToken0 == _quoteToken && poolToken1 == _baseToken;
        if (!directPair && !inversePair) {
            revert PoolTokenMismatch(poolToken0, poolToken1, _baseToken, _quoteToken);
        }

        uint8 baseDecimals = IERC20Metadata(_baseToken).decimals();
        uint8 quoteDecimals = IERC20Metadata(_quoteToken).decimals();
        if (baseDecimals > 18) {
            revert UnsupportedTokenDecimals(_baseToken, baseDecimals);
        }
        if (quoteDecimals > 18) {
            revert UnsupportedTokenDecimals(_quoteToken, quoteDecimals);
        }

        baseToken = _baseToken;
        quoteToken = _quoteToken;

        baseTokenDecimals = baseDecimals;
        quoteTokenDecimals = quoteDecimals;

        baseIdentifier = _baseIdentifier;
        quoteIdentifier = _quoteIdentifier;

        twapWindow = _twapWindow;
        maxObservationStaleness = _maxObservationStaleness;
    }

    function latestPrice() external view returns (uint256 priceWad, uint256 updatedAt) {
        updatedAt = _latestObservationTimestamp();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);

        int56 tickCumulativeDelta = tickCumulatives[1] - tickCumulatives[0];

        int24 meanTick = UniswapV3OracleMath.arithmeticMeanTick(tickCumulativeDelta, twapWindow);

        uint128 baseAmount = uint128(10 ** uint256(baseTokenDecimals));

        uint256 quoteAmount = UniswapV3OracleMath.getQuoteAtTick(meanTick, baseAmount, baseToken, quoteToken);

        priceWad = DecimalMath.scale(quoteAmount, quoteTokenDecimals, 18, Math.Rounding.Floor);

        if (priceWad == 0) revert InvalidPrice();
    }

    function _latestObservationTimestamp() internal view returns (uint256 updatedAt) {
        (,, uint16 observationIndex,,,,) = pool.slot0();

        (uint32 observationTimestamp,,, bool initialized) = pool.observations(observationIndex);

        if (!initialized) revert UninitializedObservation(observationIndex);

        uint32 observationAge;

        unchecked {
            observationAge = uint32(block.timestamp) - observationTimestamp;
        }

        updatedAt = block.timestamp - uint256(observationAge);

        if (observationAge > maxObservationStaleness) {
            revert StaleObservation(updatedAt, block.timestamp, maxObservationStaleness);
        }
    }
}
