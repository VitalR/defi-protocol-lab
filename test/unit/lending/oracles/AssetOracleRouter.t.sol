// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { AssetOracleRouter, Ownable } from "src/lending/oracles/AssetOracleRouter.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";
import { PushOracleAdapter } from "src/lending/oracles/adapters/PushOracleAdapter.sol";
import { IPriceOracle } from "src/lending/oracles/interfaces/IPriceOracle.sol";
import { MockAggregatorV3 } from "test/mocks/MockAggregatorV3.sol";
import { MockWETH } from "test/mocks/MockWETH.sol";
import { MockWBTC } from "test/mocks/MockWBTC.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";

contract AssetOracleRouterTest is Test {
    AssetOracleRouter router;
    PushOracleAdapter adapter;
    MockWETH mockETH;
    MockWBTC mockWBTC;

    function setUp() public {
        router = new AssetOracleRouter(address(this));
        mockETH = new MockWETH();
        mockWBTC = new MockWBTC();
    }

    function test_setOracleConfig() public {
        (adapter,) = _setupOracleAdapterWithETH();

        vm.expectEmit(true, true, true, true);
        emit AssetOracleRouter.OracleConfigUpdated(address(mockETH), address(0), address(adapter), 18);
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 18);

        AssetOracleRouter.OracleConfig memory config = router.getOracleConfig(address(mockETH));

        assertEq(address(config.oracle), address(adapter));
        assertEq(config.baseIdentifier, bytes32("ETH"));
        assertEq(config.tokenDecimals, uint8(18));
        assertTrue(config.enabled);
    }

    function test_setOracleConfig_revertsNotOwner() public {
        (adapter,) = _setupOracleAdapterWithETH();

        address notOwner = makeAddr("notOwner");

        vm.prank(notOwner);
        vm.expectRevert();
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 18);

        AssetOracleRouter.OracleConfig memory config = router.getOracleConfig(address(mockETH));

        assertFalse(config.enabled);
    }

    function test_setOracleConfig_revertsZeroAsset() public {
        (adapter,) = _setupOracleAdapterWithETH();

        vm.expectRevert(AssetOracleRouter.ZeroAsset.selector);
        router.setOracleConfig(address(0), IPriceOracle(adapter), bytes32("ETH"), 18);

        AssetOracleRouter.OracleConfig memory config = router.getOracleConfig(address(mockETH));

        assertFalse(config.enabled);
    }

    function test_setOracleConfig_revertsZeroOracle() public {
        (adapter,) = _setupOracleAdapterWithETH();

        vm.expectRevert(AssetOracleRouter.ZeroOracle.selector);
        router.setOracleConfig(address(mockETH), IPriceOracle(address(0)), bytes32("ETH"), 18);

        AssetOracleRouter.OracleConfig memory config = router.getOracleConfig(address(mockETH));

        assertFalse(config.enabled);
    }

    function test_setOracleConfig_revertsInvalidIdentifier() public {
        (adapter,) = _setupOracleAdapterWithETH();

        vm.expectRevert(AssetOracleRouter.InvalidIdentifier.selector);
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32(0), 18);

        AssetOracleRouter.OracleConfig memory config = router.getOracleConfig(address(mockETH));

        assertFalse(config.enabled);
    }

    function test_setOracleConfig_revertsUnsupportedTokenDecimals() public {
        (adapter,) = _setupOracleAdapterWithETH();

        vm.expectRevert(abi.encodeWithSelector(AssetOracleRouter.UnsupportedTokenDecimals.selector, 19));
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 19);

        AssetOracleRouter.OracleConfig memory config = router.getOracleConfig(address(mockETH));

        assertFalse(config.enabled);
    }

    function test_setOracleConfig_revertsOracleBaseMismatch() public {
        (adapter,) = _setupOracleAdapterWithETH();

        vm.expectRevert(
            abi.encodeWithSelector(AssetOracleRouter.OracleBaseMismatch.selector, bytes32("WBTC"), bytes32("ETH"))
        );
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("WBTC"), 18);
    }

    function test_setOracleConfig_revertsOracleQuoteMismatch() public {
        MockAggregatorV3 feedETH = new MockAggregatorV3(uint256(1), uint8(18), "MockAggregatorV3::ETH/EUR");
        uint256 expectedUpdatedAt = block.timestamp;
        feedETH.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1,
                answer: 2200e18,
                startedAt: block.timestamp,
                updatedAt: expectedUpdatedAt,
                answeredInRound: 1
            })
        );
        adapter = new PushOracleAdapter(address(feedETH), bytes32("ETH"), bytes32("EUR"), 1 hours);

        vm.expectRevert(
            abi.encodeWithSelector(AssetOracleRouter.OracleQuoteMismatch.selector, bytes32("USD"), bytes32("EUR"))
        );
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 18);
    }

    function test_setOracleConfig_update() public {
        (PushOracleAdapter adapterInitial,) = _setupOracleAdapterWithETH();

        vm.expectEmit(true, true, true, true);
        emit AssetOracleRouter.OracleConfigUpdated(address(mockETH), address(0), address(adapterInitial), 18);
        router.setOracleConfig(address(mockETH), IPriceOracle(adapterInitial), bytes32("ETH"), 18);

        AssetOracleRouter.OracleConfig memory config = router.getOracleConfig(address(mockETH));

        assertEq(address(config.oracle), address(adapterInitial));
        assertEq(config.baseIdentifier, bytes32("ETH"));
        assertEq(config.tokenDecimals, uint8(18));
        assertTrue(config.enabled);

        (PushOracleAdapter adapterNew,) = _setupOracleAdapterWithETH();

        vm.expectEmit(true, true, true, true);
        emit AssetOracleRouter.OracleConfigUpdated(address(mockETH), address(adapterInitial), address(adapterNew), 18);
        router.setOracleConfig(address(mockETH), IPriceOracle(adapterNew), bytes32("ETH"), 18);

        config = router.getOracleConfig(address(mockETH));

        assertEq(address(config.oracle), address(adapterNew));
        assertEq(config.baseIdentifier, bytes32("ETH"));
        assertEq(config.tokenDecimals, uint8(18));
        assertTrue(config.enabled);
    }

    function test_setOracleConfig_twoAssetsRouteDifferentAdapters() public {
        (PushOracleAdapter adapter1,) = _setupOracleAdapterWithETH();

        vm.expectEmit(true, true, true, true);
        emit AssetOracleRouter.OracleConfigUpdated(address(mockETH), address(0), address(adapter), 18);
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter1), bytes32("ETH"), 18);

        AssetOracleRouter.OracleConfig memory config = router.getOracleConfig(address(mockETH));

        assertEq(address(config.oracle), address(adapter1));
        assertEq(config.baseIdentifier, bytes32("ETH"));
        assertEq(config.tokenDecimals, uint8(18));
        assertTrue(config.enabled);

        (PushOracleAdapter adapter2,) = _setupOracleAdapterWithWBTC();

        vm.expectEmit(true, true, true, true);
        emit AssetOracleRouter.OracleConfigUpdated(address(mockWBTC), address(0), address(adapter2), 8);
        router.setOracleConfig(address(mockWBTC), IPriceOracle(adapter2), bytes32("WBTC"), 8);

        config = router.getOracleConfig(address(mockWBTC));

        assertEq(address(config.oracle), address(adapter2));
        assertEq(config.baseIdentifier, bytes32("WBTC"));
        assertEq(config.tokenDecimals, uint8(8));
        assertTrue(config.enabled);
    }

    function test_enableAsset_revertsZeroAsset() public {
        vm.expectRevert(AssetOracleRouter.ZeroAsset.selector);
        router.enableAsset(address(0));
    }

    function test_enableAsset_revertsNotOwner() public {
        (adapter,) = _setupOracleAdapterWithETH();
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 18);
        AssetOracleRouter.OracleConfig memory config = router.getOracleConfig(address(mockETH));
        assertTrue(config.enabled);

        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        router.enableAsset(address(mockWBTC));
    }

    function test_disableAsset() public {
        test_setOracleConfig_twoAssetsRouteDifferentAdapters();

        vm.expectEmit(true, true, true, true);
        emit AssetOracleRouter.AssetDisabled(address(mockETH));
        router.disableAsset(address(mockETH));

        AssetOracleRouter.OracleConfig memory config = router.getOracleConfig(address(mockETH));
        assertFalse(config.enabled);
        config = router.getOracleConfig(address(mockWBTC));
        assertTrue(config.enabled);
    }

    function test_enableAsset() public {
        test_disableAsset();

        vm.expectEmit(true, true, true, true);
        emit AssetOracleRouter.AssetEnabled(address(mockETH));
        router.enableAsset(address(mockETH));

        AssetOracleRouter.OracleConfig memory config = router.getOracleConfig(address(mockETH));
        assertTrue(config.enabled);
        config = router.getOracleConfig(address(mockWBTC));
        assertTrue(config.enabled);
    }

    function test_enableAsset_revertsAssetNotConfigured() public {
        MockUSDC mockUSDC = new MockUSDC();

        vm.expectRevert(abi.encodeWithSelector(AssetOracleRouter.AssetNotConfigured.selector, address(mockUSDC)));
        router.enableAsset(address(mockUSDC));
    }

    function test_enableAsset_revertsAssetAlreadyEnabled() public {
        test_setOracleConfig();

        vm.expectRevert(abi.encodeWithSelector(AssetOracleRouter.AssetAlreadyEnabled.selector, address(mockETH)));
        router.enableAsset(address(mockETH));
    }

    function test_disableAsset_revertsZeroAsset() public {
        vm.expectRevert(AssetOracleRouter.ZeroAsset.selector);
        router.disableAsset(address(0));
    }

    function test_disableAsset_revertsAssetNotConfigured() public {
        MockUSDC mockUSDC = new MockUSDC();

        vm.expectRevert(abi.encodeWithSelector(AssetOracleRouter.AssetNotConfigured.selector, address(mockUSDC)));
        router.disableAsset(address(mockUSDC));
    }

    function test_disableAsset_revertsAssetAlreadyEnabled() public {
        test_disableAsset();

        vm.expectRevert(abi.encodeWithSelector(AssetOracleRouter.AssetAlreadyDisabled.selector, address(mockETH)));
        router.disableAsset(address(mockETH));
    }

    function test_disableAsset_revertsNotOwner() public {
        test_setOracleConfig_twoAssetsRouteDifferentAdapters();

        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        router.disableAsset(address(mockETH));

        AssetOracleRouter.OracleConfig memory config = router.getOracleConfig(address(mockETH));
        assertTrue(config.enabled);
    }

    function test_valueOf_collateral() public {
        uint256 priceUpdatedAt;
        (adapter, priceUpdatedAt) = _setupOracleAdapterWithWBTC();

        router.setOracleConfig(address(mockWBTC), IPriceOracle(adapter), bytes32("WBTC"), 8);

        uint256 amount = 2e8; // 2 WBTC

        (uint256 valueWad, uint256 updatedAt) =
            router.valueOf(address(mockWBTC), amount, AssetOracleRouter.ValueType.Collateral);

        assertEq(valueWad, 120_000e18);
        assertEq(updatedAt, 1);
    }

    function test_valueOf_debt() public {
        uint256 priceUpdatedAt;
        (adapter, priceUpdatedAt) = _setupOracleAdapterWithWBTC();

        router.setOracleConfig(address(mockWBTC), IPriceOracle(adapter), bytes32("WBTC"), 8);

        uint256 amount = 2e8; // 2 WBTC

        (uint256 valueWad, uint256 updatedAt) =
            router.valueOf(address(mockWBTC), amount, AssetOracleRouter.ValueType.Debt);

        assertEq(valueWad, 120_000e18);
        assertEq(updatedAt, 1);
    }

    function test_valueOf_revertsZeroAsset() public {
        uint256 priceUpdatedAt;
        (adapter, priceUpdatedAt) = _setupOracleAdapterWithETH();
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 18);

        vm.expectRevert(AssetOracleRouter.ZeroAsset.selector);
        router.valueOf(address(0), 2000e18, AssetOracleRouter.ValueType.Collateral);
    }

    function test_valueOf_revertsZeroAmount() public {
        uint256 priceUpdatedAt;
        (adapter, priceUpdatedAt) = _setupOracleAdapterWithETH();
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 18);

        vm.expectRevert(AssetOracleRouter.ZeroAmount.selector);
        router.valueOf(address(mockETH), 0, AssetOracleRouter.ValueType.Collateral);
    }

    function test_valueOf_revertsInvalidValueType() public {
        uint256 priceUpdatedAt;
        (adapter, priceUpdatedAt) = _setupOracleAdapterWithETH();
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 18);

        vm.expectRevert(AssetOracleRouter.InvalidValueType.selector);
        router.valueOf(address(mockETH), 1000, AssetOracleRouter.ValueType.Undefined);
    }

    function test_collateralValueOf() public {
        uint256 priceUpdatedAt;
        (adapter, priceUpdatedAt) = _setupOracleAdapterWithETH();
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 18);

        (uint256 valueWad, uint256 updatedAt) = router.collateralValueOf(address(mockETH), 2);

        assertEq(valueWad, 4000);
        assertEq(updatedAt, 1);
    }

    function test_collateralValueOf_revertsZeroAmount() public {
        uint256 priceUpdatedAt;
        (adapter, priceUpdatedAt) = _setupOracleAdapterWithETH();
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 18);
        vm.expectRevert(AssetOracleRouter.ZeroAmount.selector);
        router.collateralValueOf(address(mockETH), 0);
    }

    function test_collateralValueOf_revertsZeroAsset() public {
        uint256 priceUpdatedAt;
        (adapter, priceUpdatedAt) = _setupOracleAdapterWithETH();
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 18);
        vm.expectRevert(AssetOracleRouter.ZeroAsset.selector);
        router.collateralValueOf(address(0), 10);
    }

    function test_collateralValueOf_revertsAssetNotConfigured() public {
        uint256 priceUpdatedAt;
        (adapter, priceUpdatedAt) = _setupOracleAdapterWithETH();
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 18);
        vm.expectRevert(abi.encodeWithSelector(AssetOracleRouter.AssetNotConfigured.selector, address(mockWBTC)));
        router.collateralValueOf(address(mockWBTC), 10);
    }

    function test_collateralValueOf_revertsAssetNotEnabled() public {
        test_disableAsset();

        vm.expectRevert(abi.encodeWithSelector(AssetOracleRouter.AssetNotEnabled.selector, address(mockETH)));
        router.collateralValueOf(address(mockETH), 10);
    }

    function test_debtValueOf() public {
        uint256 priceUpdatedAt;
        (adapter, priceUpdatedAt) = _setupOracleAdapterWithETH();
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 18);

        (uint256 valueWad, uint256 updatedAt) = router.debtValueOf(address(mockETH), 2);

        assertEq(valueWad, 4000);
        assertEq(updatedAt, 1);
    }

    function test_debtValueOf_revertsZeroAmount() public {
        uint256 priceUpdatedAt;
        (adapter, priceUpdatedAt) = _setupOracleAdapterWithETH();
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 18);
        vm.expectRevert(AssetOracleRouter.ZeroAmount.selector);
        router.debtValueOf(address(mockETH), 0);
    }

    function test_debtValueOf_revertsZeroAsset() public {
        uint256 priceUpdatedAt;
        (adapter, priceUpdatedAt) = _setupOracleAdapterWithETH();
        router.setOracleConfig(address(mockETH), IPriceOracle(adapter), bytes32("ETH"), 18);
        vm.expectRevert(AssetOracleRouter.ZeroAsset.selector);
        router.debtValueOf(address(0), 10);
    }

    function test_wrappers_enforceConservativeRounding() public {
        MockAggregatorV3 feed = new MockAggregatorV3(1, 18, "TOKEN/USD");

        feed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1,
                answer: int256(1e18 + 1),
                startedAt: block.timestamp,
                updatedAt: block.timestamp,
                answeredInRound: 1
            })
        );

        PushOracleAdapter roundingAdapter =
            new PushOracleAdapter(address(feed), bytes32("TOKEN"), bytes32("USD"), 1 hours);

        router.setOracleConfig(address(mockETH), IPriceOracle(roundingAdapter), bytes32("TOKEN"), 18);

        (uint256 collateralValue,) = router.collateralValueOf(address(mockETH), 1);

        (uint256 debtValue,) = router.debtValueOf(address(mockETH), 1);

        assertEq(collateralValue, 1);
        assertEq(debtValue, 2);
    }

    function _setupOracleAdapterWithETH() private returns (PushOracleAdapter, uint256) {
        MockAggregatorV3 feedETH = new MockAggregatorV3(uint256(1), uint8(18), "MockAggregatorV3::ETH/USD");
        uint256 expectedUpdatedAt = block.timestamp;
        feedETH.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1,
                answer: 2000e18,
                startedAt: block.timestamp,
                updatedAt: expectedUpdatedAt,
                answeredInRound: 1
            })
        );

        adapter = new PushOracleAdapter(address(feedETH), bytes32("ETH"), bytes32("USD"), 1 hours);

        return (adapter, expectedUpdatedAt);
    }

    function _setupOracleAdapterWithWBTC() private returns (PushOracleAdapter, uint256) {
        MockAggregatorV3 feedWBTC = new MockAggregatorV3(uint256(1), uint8(8), "MockAggregatorV3::WBTC/USD");
        uint256 expectedUpdatedAt = block.timestamp;
        feedWBTC.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1,
                answer: 60_000e8,
                startedAt: block.timestamp,
                updatedAt: expectedUpdatedAt,
                answeredInRound: 1
            })
        );

        adapter = new PushOracleAdapter(address(feedWBTC), bytes32("WBTC"), bytes32("USD"), 1 hours);

        return (adapter, expectedUpdatedAt);
    }
}
