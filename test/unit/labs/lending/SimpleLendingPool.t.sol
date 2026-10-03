// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { SimpleLendingPool } from "src/labs/lending/SimpleLendingPool.sol";
import { InterestRateModel } from "src/labs/lending/InterestRateModel.sol";
import { PushOracleAdapter } from "src/labs/oracles/PushOracleAdapter.sol";
import { MockAggregatorV3 } from "test/mocks/MockAggregatorV3.sol";
import { TokenTransfer, IERC20 } from "src/common/token/TokenTransfer.sol";
import { MockFeeOnTransferERC20 } from "test/mocks/MockFeeOnTransferERC20.sol";
import { MockWETH } from "test/mocks/MockWETH.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";
import { DecimalMath, Math } from "src/common/math/DecimalMath.sol";

contract SimpleLendingPoolTest is Test {
    SimpleLendingPool lending;
    InterestRateModel rateModel;
    PushOracleAdapter adapter;
    MockAggregatorV3 feed;
    MockWETH mockWETH;
    MockUSDC mockUSDC;

    address user = address(0x1001);

    event Supplied(address indexed user, address indexed collateralToken, uint256 amount);
    event Borrowed(address indexed user, address indexed debtToken, uint256 amount);
    event Withdrawn(address indexed user, address indexed collateralToken, uint256 amount);
    event Repaid(address indexed user, address indexed debtToken, uint256 amount);
    event Liquidated(
        address indexed liquidator, address indexed borrower, uint256 debtToRepay, uint256 collateralToSeize
    );

    function setUp() public {
        feed = new MockAggregatorV3(uint256(1), uint8(8), "MockAggregatorV3::ETH/USD");
        adapter = new PushOracleAdapter(address(feed), bytes32("ETH"), bytes32("USD"), 1 hours);
        rateModel = new InterestRateModel();

        mockWETH = new MockWETH();
        mockUSDC = new MockUSDC();

        mockWETH.mint(user, 10 ether);

        lending = new SimpleLendingPool(address(mockWETH), address(mockUSDC), address(adapter), address(rateModel));
    }

    function test_deployment_configuration() public {
        assertEq(address(lending.collateralToken()), address(mockWETH));
        assertEq(address(lending.debtToken()), address(mockUSDC));
        assertEq(address(lending.oracle()), address(adapter));
        assertEq(address(lending.interestRateModel()), address(rateModel));
        assertEq(lending.borrowIndex(), 1e18);
        assertEq(lending.lastInterestUpdate(), block.timestamp);
    }

    function test_deployment_configuration_reverts() public {
        vm.expectRevert(SimpleLendingPool.ZeroAddress.selector);
        new SimpleLendingPool(address(0), address(mockUSDC), address(adapter), address(rateModel));

        vm.expectRevert(SimpleLendingPool.ZeroAddress.selector);
        new SimpleLendingPool(address(mockWETH), address(0), address(adapter), address(rateModel));

        vm.expectRevert(SimpleLendingPool.ZeroAddress.selector);
        new SimpleLendingPool(address(mockWETH), address(mockUSDC), address(0), address(rateModel));

        vm.expectRevert(SimpleLendingPool.ZeroAddress.selector);
        new SimpleLendingPool(address(mockWETH), address(mockUSDC), address(adapter), address(0));
    }

    function test_supplyCollateral_pullsExactAmount() public {
        assertEq(mockWETH.balanceOf(user), 10 ether);
        assertEq(lending.collateralOf(user), 0);

        vm.startPrank(user);
        mockWETH.approve(address(lending), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit Supplied(user, address(mockWETH), 1 ether);
        lending.supplyCollateral(1 ether);

        vm.stopPrank();

        assertEq(mockWETH.balanceOf(user), 9 ether);
        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(mockWETH.balanceOf(address(lending)), 1 ether);
        assertEq(lending.totalDebt(), 0);
    }

    function test_supplyCollateral_reverts_whenAmountIsZero() public {
        assertEq(mockWETH.balanceOf(user), 10 ether);
        assertEq(lending.collateralOf(user), 0);

        vm.startPrank(user);
        mockWETH.approve(address(lending), 1 ether);

        vm.expectRevert(SimpleLendingPool.ZeroAmount.selector);
        lending.supplyCollateral(0);
        vm.stopPrank();

        assertEq(mockWETH.balanceOf(user), 10 ether);
        assertEq(lending.collateralOf(user), 0 ether);
    }

    function _supply(address account, uint256 amount) internal {
        vm.startPrank(account);
        mockWETH.approve(address(lending), amount);
        lending.supplyCollateral(amount);
        vm.stopPrank();
    }

    function test_supplyCollateral_accumulatesForSameUser() public {
        _supply(user, 1 ether);

        assertEq(mockWETH.balanceOf(user), 9 ether);
        assertEq(lending.collateralOf(user), 1 ether);

        vm.startPrank(user);
        mockWETH.approve(address(lending), 3 ether);

        lending.supplyCollateral(3 ether);
        vm.stopPrank();

        assertEq(mockWETH.balanceOf(user), 6 ether);
        assertEq(lending.collateralOf(user), 4 ether);
    }

    function test_supplyCollateral_tracksUsersIndependently() public {
        _supply(user, 1 ether);

        assertEq(mockWETH.balanceOf(user), 9 ether);
        assertEq(lending.collateralOf(user), 1 ether);

        address user2 = address(0x1002);
        mockWETH.mint(user2, 2 ether);

        vm.startPrank(user2);
        mockWETH.approve(address(lending), 1 ether);

        lending.supplyCollateral(1 ether);
        vm.stopPrank();

        assertEq(mockWETH.balanceOf(user), 9 ether);
        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(mockWETH.balanceOf(user2), 1 ether);
        assertEq(lending.collateralOf(user2), 1 ether);
        assertEq(mockWETH.balanceOf(address(lending)), 2 ether);
    }

    function test_supplyCollateral_reverts_whenTokenWithFeeOnTransfer() public {
        address user2 = address(0x1002);

        uint256 amount = 1 ether;
        uint256 fee = 500;
        uint256 expectedReceived = amount - fee;

        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20(user, fee);
        feeToken.mint(user2, 10 ether);

        SimpleLendingPool lending2 =
            new SimpleLendingPool(address(feeToken), address(mockUSDC), address(adapter), address(rateModel));

        assertEq(IERC20(feeToken).balanceOf(user2), 10 ether);
        assertEq(lending2.collateralOf(user2), 0);

        vm.startPrank(user2);
        feeToken.approve(address(lending2), amount);
        vm.expectRevert(
            abi.encodeWithSelector(TokenTransfer.UnexpectedAmountReceived.selector, amount, expectedReceived)
        );
        lending2.supplyCollateral(amount);
        vm.stopPrank();

        assertEq(IERC20(feeToken).balanceOf(user2), 10 ether);
        assertEq(lending2.collateralOf(user2), 0 ether);
    }

    function test_supplyCollateral_reverts_whenAllowanceIsInsufficient() public {
        assertEq(mockWETH.balanceOf(user), 10 ether);
        assertEq(lending.collateralOf(user), 0);

        vm.startPrank(user);
        mockWETH.approve(address(lending), 0.5 ether);

        vm.expectRevert();
        // vm.expectRevert(abi.encodeWithSelector(mockWETH.ERC20InsufficientAllowance.selector,
        // 0xc7183455a4C133Ae270771860664b6B7ec320bB1, 0.5 ether, 1 ether));
        lending.supplyCollateral(1 ether);

        vm.stopPrank();

        assertEq(mockWETH.balanceOf(user), 10 ether);
        assertEq(lending.collateralOf(user), 0 ether);
        assertEq(mockWETH.balanceOf(address(lending)), 0 ether);
    }

    function _setLatestPriceOracle(int256 price) internal {
        // answer: 2000e8
        feed.setLatestRoundData(
            MockAggregatorV3.PriceData({
                roundId: 1, answer: price, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: 1
            })
        );
    }

    function _fundsPool() internal {
        assertEq(mockUSDC.balanceOf(address(lending)), 0);
        mockUSDC.mint(address(lending), 10_000e6);
        assertEq(mockUSDC.balanceOf(address(lending)), 10_000e6);
    }

    // 1 WETH @ $2,000
    // LTV 75%

    // maxBorrow() == 1500e6

    // borrow(1500e6)       → success
    // borrow(1500e6 + 1)   → revert

    // borrow(1000e6)
    // then borrow(500e6)   → success

    // borrow(1000e6)
    // then borrow(500e6+1) → revert
    function test_borrow_pushExactAmount() public {
        _fundsPool();
        _setLatestPriceOracle(int256(2000e8));

        uint256 userBalanceBefor = mockWETH.balanceOf(user);

        assertEq(mockWETH.balanceOf(user), userBalanceBefor); //10 ether
        assertEq(lending.collateralOf(user), 0);
        assertEq(lending.debtOf(user), 0);

        uint256 supplyAmount = 1 ether;

        vm.startPrank(user);
        mockWETH.approve(address(lending), supplyAmount);
        lending.supplyCollateral(supplyAmount);

        uint256 borrowAmount = 1500e6;
        assertEq(lending.debtOf(user), 0);

        vm.expectEmit(true, true, true, true);
        emit Borrowed(user, address(mockUSDC), borrowAmount);
        lending.borrow(borrowAmount);

        vm.stopPrank();

        assertEq(mockWETH.balanceOf(user), userBalanceBefor - supplyAmount);
        assertEq(lending.collateralOf(user), supplyAmount);
        assertEq(mockWETH.balanceOf(address(lending)), supplyAmount);

        assertEq(mockUSDC.balanceOf(user), borrowAmount);
        assertEq(mockUSDC.balanceOf(address(lending)), 10_000e6 - borrowAmount);

        assertEq(lending.debtOf(user), borrowAmount);
        assertEq(lending.availableToBorrow(user), lending.maxBorrow(user) - borrowAmount);
        assertEq(lending.collateralValue(user), 2000e18);
        assertEq(lending.maxBorrow(user), 1500e6);
        assertEq(lending.totalDebt(), borrowAmount);
    }

    function test_borrow_reverts_whenBorrowCapacityExceeded() public {
        _fundsPool();
        _setLatestPriceOracle(int256(2000e8));

        uint256 userBalanceBefor = mockWETH.balanceOf(user);

        assertEq(mockWETH.balanceOf(user), userBalanceBefor); //10 ether
        assertEq(lending.collateralOf(user), 0);
        assertEq(lending.debtOf(user), 0);

        uint256 supplyAmount = 1 ether;

        vm.startPrank(user);
        mockWETH.approve(address(lending), supplyAmount);
        lending.supplyCollateral(supplyAmount);

        uint256 maxBorrow = lending.maxBorrow(user);
        uint256 borrowAmount = maxBorrow + 1; //1501e6
        assertEq(lending.debtOf(user), 0);
        assertEq(lending.totalDebt(), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                SimpleLendingPool.BorrowCapacityExceeded.selector, borrowAmount, lending.maxBorrow(user)
            )
        );
        lending.borrow(borrowAmount);

        vm.stopPrank();
    }

    function test_borrow_accumulatesDebtAcrossMultipleBorrows() public {
        _fundsPool();
        _setLatestPriceOracle(int256(2000e8));

        uint256 userBalanceBefor = mockWETH.balanceOf(user);

        assertEq(mockWETH.balanceOf(user), userBalanceBefor); //10 ether
        assertEq(lending.collateralOf(user), 0);
        assertEq(lending.debtOf(user), 0);

        uint256 supplyAmount = 1 ether;

        vm.startPrank(user);
        mockWETH.approve(address(lending), supplyAmount);
        lending.supplyCollateral(supplyAmount);

        uint256 borrowAmount1 = 1000e6;
        assertEq(lending.debtOf(user), 0);

        lending.borrow(borrowAmount1);

        assertEq(mockWETH.balanceOf(user), userBalanceBefor - supplyAmount);
        assertEq(lending.collateralOf(user), supplyAmount);
        assertEq(mockWETH.balanceOf(address(lending)), supplyAmount);
        assertEq(mockUSDC.balanceOf(user), borrowAmount1);
        assertEq(mockUSDC.balanceOf(address(lending)), 10_000e6 - borrowAmount1);
        assertEq(lending.debtOf(user), borrowAmount1);

        uint256 borrowAmount2 = 500e6;

        lending.borrow(borrowAmount2);

        vm.stopPrank();

        assertEq(mockWETH.balanceOf(user), userBalanceBefor - supplyAmount);
        assertEq(lending.collateralOf(user), supplyAmount);
        assertEq(mockWETH.balanceOf(address(lending)), supplyAmount);
        assertEq(mockUSDC.balanceOf(user), borrowAmount1 + borrowAmount2);
        assertEq(mockUSDC.balanceOf(address(lending)), 10_000e6 - borrowAmount1 - borrowAmount2);
        assertEq(lending.debtOf(user), borrowAmount1 + borrowAmount2);
        assertEq(lending.totalDebt(), borrowAmount1 + borrowAmount2);
    }

    function test_borrow_reverts_whenCumulativeDebtExceedsCapacity() public {
        _fundsPool();
        _setLatestPriceOracle(int256(2000e8));

        uint256 userBalanceBefor = mockWETH.balanceOf(user);

        assertEq(mockWETH.balanceOf(user), userBalanceBefor);
        assertEq(lending.collateralOf(user), 0);
        assertEq(lending.debtOf(user), 0);

        uint256 supplyAmount = 1 ether;

        vm.startPrank(user);
        mockWETH.approve(address(lending), supplyAmount);
        lending.supplyCollateral(supplyAmount);

        uint256 borrowAmount1 = 1000e6;
        assertEq(lending.debtOf(user), 0);

        lending.borrow(borrowAmount1);

        assertEq(mockWETH.balanceOf(user), userBalanceBefor - supplyAmount);
        assertEq(lending.collateralOf(user), supplyAmount);
        assertEq(mockWETH.balanceOf(address(lending)), supplyAmount);
        assertEq(mockUSDC.balanceOf(user), borrowAmount1);
        assertEq(mockUSDC.balanceOf(address(lending)), 10_000e6 - borrowAmount1);
        assertEq(lending.debtOf(user), borrowAmount1);

        uint256 borrowAmount2 = 501e6;

        vm.expectRevert(
            abi.encodeWithSelector(
                SimpleLendingPool.BorrowCapacityExceeded.selector,
                borrowAmount1 + borrowAmount2,
                lending.maxBorrow(user)
            )
        );

        lending.borrow(borrowAmount2);

        vm.stopPrank();

        assertEq(mockWETH.balanceOf(user), userBalanceBefor - supplyAmount);
        assertEq(lending.collateralOf(user), supplyAmount);
        assertEq(mockWETH.balanceOf(address(lending)), supplyAmount);
        assertEq(mockUSDC.balanceOf(user), borrowAmount1);
        assertEq(mockUSDC.balanceOf(address(lending)), 10_000e6 - borrowAmount1);
        assertEq(lending.debtOf(user), borrowAmount1);
        assertEq(lending.totalDebt(), borrowAmount1);
    }

    function test_maxBorrow_returnsDebtTokenNativeUnits() public {
        _fundsPool();
        _setLatestPriceOracle(int256(2000e8));

        assertEq(lending.collateralValue(user), 0);
        assertEq(lending.maxBorrow(user), 0);

        vm.startPrank(user);
        mockWETH.approve(address(lending), 1 ether);
        lending.supplyCollateral(1 ether);
        lending.borrow(1500e6);
        vm.stopPrank();

        assertEq(lending.collateralValue(user), 2000e18); // 1 ether * wethPrice
        assertEq(lending.maxBorrow(user), 1500e6); // collateralValue * LTV => wad to debt token units
    }

    function test_borrow_revertsWhenAmountIsZero() public {
        _fundsPool();
        _setLatestPriceOracle(int256(2000e8));

        assertEq(lending.collateralOf(user), 0);
        assertEq(lending.debtOf(user), 0);

        vm.startPrank(user);
        mockWETH.approve(address(lending), 1 ether);
        lending.supplyCollateral(1 ether);

        vm.expectRevert(SimpleLendingPool.ZeroAmount.selector);
        lending.borrow(0e6);
        vm.stopPrank();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 0);
    }

    function test_availableToBorrow() public {
        _fundsPool();
        _setLatestPriceOracle(int256(2000e8));

        assertEq(lending.collateralValue(user), 0);
        assertEq(lending.maxBorrow(user), 0);

        vm.startPrank(user);
        mockWETH.approve(address(lending), 1 ether);
        lending.supplyCollateral(1 ether);
        lending.borrow(1500e6);
        vm.stopPrank();

        assertEq(lending.collateralValue(user), 2000e18);
        assertEq(lending.maxBorrow(user), 1500e6);

        _setLatestPriceOracle(int256(1900e8));

        assertEq(lending.maxBorrow(user), 1425e6);
        assertEq(lending.debtOf(user), 1500e6);
        assertEq(lending.availableToBorrow(user), 0);
    }

    function _openMaxBorrowPosition() internal {
        _fundsPool();
        _setLatestPriceOracle(2000e8);

        vm.startPrank(user);
        mockWETH.approve(address(lending), 1 ether);
        lending.supplyCollateral(1 ether);
        lending.borrow(1500e6);
        vm.stopPrank();
    }

    function test_healthFactor_noDebt() public {
        _fundsPool();
        _setLatestPriceOracle(2000e8);

        vm.startPrank(user);
        mockWETH.approve(address(lending), 1 ether);
        lending.supplyCollateral(1 ether);
        vm.stopPrank();

        assertEq(lending.collateralValue(user), 2000e18);
        assertEq(lending.maxBorrow(user), 1500e6);

        assertEq(lending.healthFactor(user), type(uint256).max);
    }

    function test_healthFactor_withDebt() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralValue(user), 2000e18);
        assertEq(lending.maxBorrow(user), 1500e6);

        assertGe(lending.healthFactor(user), 1_066_666_666_666_666_666);
    }

    function test_healthFactor_whenBorrowDisabledButStillHealthy() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralValue(user), 2000e18);
        assertEq(lending.maxBorrow(user), 1500e6);

        assertGt(lending.healthFactor(user), 1e18);

        _setLatestPriceOracle(int256(1900e8));

        assertEq(lending.maxBorrow(user), 1425e6);
        assertEq(lending.debtOf(user), 1500e6);
        assertEq(lending.availableToBorrow(user), 0);

        // LTV capacity = 1425
        // debt = 1500

        // cannot borrow more
        // but

        // 1900 × 80% = 1520
        // HF = 1520 / 1500 > 1

        assertGt(lending.healthFactor(user), 1e18);
    }

    function test_healthFactor_whenExactLiquidationBoundary() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralValue(user), 2000e18);
        assertEq(lending.maxBorrow(user), 1500e6);

        assertGt(lending.healthFactor(user), 1e18);

        _setLatestPriceOracle(int256(1875e8));

        assertEq(lending.maxBorrow(user), 1_406_250_000);
        assertEq(lending.debtOf(user), 1500e6);
        assertEq(lending.availableToBorrow(user), 0);

        // 1875 × 80% = 1500
        // HF = 1

        assertEq(lending.healthFactor(user), 1e18);
    }

    function test_healthFactor_liquidatable() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralValue(user), 2000e18);
        assertEq(lending.maxBorrow(user), 1500e6);

        assertGt(lending.healthFactor(user), 1e18);

        _setLatestPriceOracle(int256(1800e8));

        assertEq(lending.maxBorrow(user), 1_350_000_000);
        assertEq(lending.debtOf(user), 1500e6);
        assertEq(lending.availableToBorrow(user), 0);

        // 1800 × 80% = 1440
        // HF = 1440 / 1500 = 0.96

        assertLt(lending.healthFactor(user), 1e18);
    }

    function test_withdraw_noDebt_fullCollateralWithdrawalSucceeds() public {
        _supply(user, 1 ether);

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 0);

        assertEq(lending.healthFactor(user), type(uint256).max);

        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit Withdrawn(user, address(mockWETH), 1 ether);
        lending.withdrawCollateral(1 ether);

        assertEq(lending.collateralOf(user), 0);
        assertEq(lending.debtOf(user), 0);

        assertEq(lending.healthFactor(user), type(uint256).max);
    }

    function test_withdraw_partialWithdrawalUpdateAccounting() public {
        _fundsPool();
        _setLatestPriceOracle(2000e8);

        vm.startPrank(user);
        mockWETH.approve(address(lending), 1 ether);
        lending.supplyCollateral(1 ether);
        lending.borrow(1000e6);

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1000e6);

        // adjusted collateral = 2000 × 0.8 = 1600
        // HF = 1600 / 1000 = 1.6
        assertEq(lending.healthFactor(user), 1.6e18);
        assertEq(lending.availableToBorrow(user), 500e6);

        lending.withdrawCollateral(0.25 ether);

        assertEq(lending.collateralOf(user), 0.75 ether);
        assertEq(lending.debtOf(user), 1000e6);

        assertEq(mockWETH.balanceOf(user), 9.25 ether);
        assertEq(mockWETH.balanceOf(address(lending)), 0.75 ether);

        // Remaining: 0.75 WETH = $1500
        // Adjusted: 1500 × 80% = $1200
        // HF: 1200 / 1000 = 1.2
        assertEq(lending.healthFactor(user), 1.2e18);
        assertEq(lending.availableToBorrow(user), 125e6);

        lending.withdrawCollateral(0.125 ether);

        // Remaining: 0.625 WETH = $1250
        // Adjusted: 1250 × 80% = $1000
        // HF: 1.0
        assertEq(lending.healthFactor(user), 1e18);
        assertEq(lending.availableToBorrow(user), 0);

        assertEq(mockWETH.balanceOf(user), 9.375 ether);
        assertEq(mockWETH.balanceOf(address(lending)), 0.625 ether);

        // Withdraw one wei more
        vm.expectRevert(abi.encodeWithSelector(SimpleLendingPool.UnhealthyPosition.selector, 999_999_999_999_999_998));
        lending.withdrawCollateral(1 wei);

        vm.stopPrank();

        assertEq(lending.collateralOf(user), 0.625 ether);
        assertEq(lending.debtOf(user), 1000e6);

        assertEq(mockWETH.balanceOf(user), 9.375 ether);
        assertEq(mockWETH.balanceOf(address(lending)), 0.625 ether);

        assertEq(lending.healthFactor(user), 1e18);
    }

    function test_withdraw_revertsWhenAmountIsZero() public {
        _supply(user, 1 ether);

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 0);

        assertEq(lending.healthFactor(user), type(uint256).max);

        vm.prank(user);
        vm.expectRevert(SimpleLendingPool.ZeroAmount.selector);
        lending.withdrawCollateral(0 ether);

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 0);

        assertEq(lending.healthFactor(user), type(uint256).max);
    }

    function test_withdraw_revertsWhenAmountExceedsCollateral() public {
        _supply(user, 1 ether);

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 0);

        assertEq(lending.healthFactor(user), type(uint256).max);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SimpleLendingPool.InsufficientCollateral.selector, 1.1 ether, 1 ether));
        lending.withdrawCollateral(1.1 ether);

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 0);

        assertEq(lending.healthFactor(user), type(uint256).max);
    }

    function test_repay_fullDept() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);
        assertEq(lending.totalDebt(), 1500e6);

        assertEq(lending.healthFactor(user), 1_066_666_666_666_666_666);

        uint256 poolBalanceBefore = mockUSDC.balanceOf(address(lending));

        vm.startPrank(user);
        mockUSDC.approve(address(lending), 1500e6);

        vm.expectEmit(true, true, true, true);
        emit Repaid(user, address(mockUSDC), 1500e6);
        lending.repay(1500e6);

        vm.stopPrank();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 0);
        assertEq(lending.totalDebt(), 0);

        assertEq(mockUSDC.balanceOf(address(lending)), poolBalanceBefore + 1500e6);

        assertEq(lending.healthFactor(user), type(uint256).max);
    }

    function test_repay_partialRepaidUpdateAccounting() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        assertEq(lending.healthFactor(user), 1_066_666_666_666_666_666);

        vm.startPrank(user);
        mockUSDC.approve(address(lending), 500e6);
        lending.repay(500e6);

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1000e6);

        assertEq(lending.healthFactor(user), 1_600_000_000_000_000_000);

        mockUSDC.approve(address(lending), 500e6);
        lending.repay(500e6);

        vm.stopPrank();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 500e6);
        assertEq(lending.totalDebt(), 500e6);

        assertEq(lending.healthFactor(user), 3_200_000_000_000_000_000);
    }

    function test_repay_revertsWhenAmountIsZero() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        assertEq(lending.healthFactor(user), 1_066_666_666_666_666_666);

        vm.startPrank(user);
        mockUSDC.approve(address(lending), 1500e6);
        vm.expectRevert(SimpleLendingPool.ZeroAmount.selector);
        lending.repay(0e6);

        vm.stopPrank();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);
        assertEq(lending.totalDebt(), 1500e6);

        assertEq(lending.healthFactor(user), 1_066_666_666_666_666_666);
    }

    function test_repay_revertsWhenCurrentDebtExceeded() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        assertEq(lending.healthFactor(user), 1_066_666_666_666_666_666);

        vm.startPrank(user);
        mockUSDC.approve(address(lending), 1501e6);
        vm.expectRevert(abi.encodeWithSelector(SimpleLendingPool.CurrentDebtExceeded.selector, 1501e6, 1500e6));
        lending.repay(1501e6);

        vm.stopPrank();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        assertEq(lending.healthFactor(user), 1_066_666_666_666_666_666);
    }

    function test_repay_revertsWhenAllowanceIsInsufficient() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        uint256 originalHF = lending.healthFactor(user); //1_066_666_666_666_666_666

        assertEq(lending.healthFactor(user), originalHF);

        vm.startPrank(user);
        mockUSDC.approve(address(lending), 499e6);
        vm.expectRevert(); //ERC20InsufficientAllowance(0xc7183455a4C133Ae270771860664b6B7ec320bB1, 499000000 [4.99e8],
        // 500000000 [5e8])]
        lending.repay(500e6);

        vm.stopPrank();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);
        assertEq(lending.totalDebt(), 1500e6);

        assertEq(lending.healthFactor(user), originalHF);
    }

    function test_repay_revertsWhenDebtReductionTooSmall() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        // Make the current borrow index greater than 1e18.
        skip(365 days);

        uint256 debtBefore = lending.debtOf(user);

        assertGt(lending.currentBorrowIndex(), 1e18);
        assertGt(debtBefore, 1500e6);

        vm.startPrank(user);
        mockUSDC.approve(address(lending), 1);

        vm.expectRevert(abi.encodeWithSelector(SimpleLendingPool.DebtReductionTooSmall.selector, 1));

        lending.repay(1);

        vm.stopPrank();

        assertEq(lending.debtOf(user), debtBefore);
    }

    // | Operation         | Risk effect | Constraint                    |
    // | ----------------- | ----------- | ----------------------------- |
    // | Supply collateral | improves    | exact custody                 |
    // | Borrow            | worsens     | resulting debt ≤ LTV capacity |
    // | Repay             | improves    | repayment ≤ current debt      |
    // | Withdraw          | worsens     | resulting HF ≥ 1              |
    // | Price drop        | worsens     | may move HF below 1           |

    function test_maxLiquidatableDebt() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        assertEq(lending.maxLiquidatableDebt(user), 750e6);

        _setLatestPriceOracle(1800e8);

        assertEq(lending.maxLiquidatableDebt(user), 750e6);
    }

    function test_maxLiquidatableDebt_revertsWhenZeroAddress() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        _setLatestPriceOracle(1800e8);

        vm.expectRevert(SimpleLendingPool.ZeroAddress.selector);
        lending.maxLiquidatableDebt(address(0));
    }

    function test_collateralToSeize() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        _setLatestPriceOracle(1800e8);

        assertEq(lending.collateralToSeize(750e6), 0.4375 ether);
    }

    function test_collateralToSeize_revertsWhenZeroAmount() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        _setLatestPriceOracle(1800e8);

        vm.expectRevert(SimpleLendingPool.ZeroAmount.selector);
        lending.collateralToSeize(0);
    }

    function test_collateralToSeize_includesLiquidationBonus() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        _setLatestPriceOracle(1800e8);

        uint256 seizeValueWadWithoutBonus = Math.mulDiv(750e18, 500, 10_000, Math.Rounding.Trunc);

        uint256 collateralAmountWithoutBonus =
            Math.mulDiv(seizeValueWadWithoutBonus, 10 ** 18, 1800e18, Math.Rounding.Floor);

        uint256 collateralAmount = lending.collateralToSeize(750e6);

        assertGt(collateralAmount, collateralAmountWithoutBonus);
    }

    // Canonical case:
    // Alice:
    // 1 WETH collateral
    // 1500 USDC debt

    // ETH:
    // $2000 → $1800

    // HF:
    // 1.0667 → 0.96

    // Liquidator repays:
    // 750 USDC

    // Seizes:
    // 0.4375 WETH

    // After liquidation:
    // borrower debt:
    // 1500 → 750 USDC

    // borrower collateral:
    // 1 → 0.5625 WETH

    // And:
    // liquidator:
    // USDC -750
    // WETH +0.4375

    // Pool:
    // USDC +750
    // WETH -0.4375

    // new HF = 1.08
    function test_liquidate() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        _setLatestPriceOracle(1800e8);

        uint256 hfBefor = lending.healthFactor(user);

        assertEq(hfBefor, 960_000_000_000_000_000);

        uint256 debtToRepay = lending.maxLiquidatableDebt(user);
        uint256 collateralAmount = lending.collateralToSeize(debtToRepay);

        uint256 poolDebtBalanceBefore = mockUSDC.balanceOf(address(lending));

        address liquidator = address(0x1002);
        mockUSDC.mint(liquidator, 1000e6);

        uint256 debtBalanceBefore = mockUSDC.balanceOf(liquidator);
        uint256 collateralBalanceBefore = mockWETH.balanceOf(liquidator);

        vm.startPrank(liquidator);
        mockUSDC.approve(address(lending), debtToRepay);

        vm.expectEmit(true, true, true, true);
        emit Liquidated(liquidator, user, debtToRepay, collateralAmount);
        lending.liquidate(user, debtToRepay);
        vm.stopPrank();

        assertEq(lending.collateralOf(user), 1 ether - collateralAmount);
        assertEq(lending.debtOf(user), 1500e6 - debtToRepay);
        assertEq(lending.totalDebt(), 1500e6 - debtToRepay);

        assertEq(mockUSDC.balanceOf(liquidator), debtBalanceBefore - debtToRepay);
        assertEq(mockWETH.balanceOf(liquidator), collateralBalanceBefore + collateralAmount);

        assertEq(mockWETH.balanceOf(address(lending)), 1 ether - collateralAmount);
        assertEq(mockUSDC.balanceOf(address(lending)), poolDebtBalanceBefore + debtToRepay);

        uint256 hfAfter = lending.healthFactor(user);

        assertGt(hfAfter, hfBefor);

        // When ETH $1800:
        // collateral value = 0.5625 × 1800
        //          = 1012.5

        // adjusted collateral = 1012.5 × 80%
        //                     = 810

        // HF = 810 / 750
        // = 1.08
        assertEq(hfAfter, 1_080_000_000_000_000_000);
    }

    function test_liquidate_revertsWhenZeroAddress() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        _setLatestPriceOracle(1800e8);

        assertEq(lending.healthFactor(user), 960_000_000_000_000_000);

        address liquidator = address(0x1002);
        mockUSDC.mint(liquidator, 1000e6);

        vm.startPrank(liquidator);
        mockUSDC.approve(address(lending), 1000e6);

        vm.expectRevert(SimpleLendingPool.ZeroAddress.selector);
        lending.liquidate(address(0), uint256(750e6));
        vm.stopPrank();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);
        assertEq(lending.totalDebt(), 1500e6);
        assertEq(lending.healthFactor(user), 960_000_000_000_000_000);
    }

    function test_liquidate_revertsWhenZeroAmount() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        _setLatestPriceOracle(1800e8);

        address liquidator = address(0x1002);
        mockUSDC.mint(liquidator, 1000e6);

        vm.startPrank(liquidator);
        mockUSDC.approve(address(lending), 1000e6);

        vm.expectRevert(SimpleLendingPool.ZeroAmount.selector);
        lending.liquidate(user, 0);
        vm.stopPrank();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);
        assertEq(lending.healthFactor(user), 960_000_000_000_000_000);
    }

    function test_liquidate_revertsWhenPositionNotLiquidatable() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        assertEq(lending.healthFactor(user), 1_066_666_666_666_666_666);

        address liquidator = address(0x1002);
        mockUSDC.mint(liquidator, 1000e6);

        vm.startPrank(liquidator);
        mockUSDC.approve(address(lending), 1000e6);

        vm.expectRevert(
            abi.encodeWithSelector(SimpleLendingPool.PositionNotLiquidatable.selector, 1_066_666_666_666_666_666)
        );
        lending.liquidate(user, 750e6);
        vm.stopPrank();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);
        assertEq(lending.totalDebt(), 1500e6);
        assertEq(lending.healthFactor(user), 1_066_666_666_666_666_666);
    }

    function test_liquidate_revertsWhenDebtToRepayExceedsMaxLiquidatableDebt() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        _setLatestPriceOracle(1800e8);

        address liquidator = address(0x1002);
        mockUSDC.mint(liquidator, 1000e6);

        vm.startPrank(liquidator);
        mockUSDC.approve(address(lending), 1000e6);

        vm.expectRevert(
            abi.encodeWithSelector(SimpleLendingPool.DebtToRepayExceedsMaxLiquidatableDebt.selector, 751e6, 750e6)
        );
        lending.liquidate(user, 751e6);
        vm.stopPrank();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);
        assertEq(lending.healthFactor(user), 960_000_000_000_000_000);
    }

    // collateral exhaustion / bad-debt territory
    function test_liquidate_revertsWhenCollateralToSeizeExceedsBorrowerCollateral() public {
        _openMaxBorrowPosition();

        _setLatestPriceOracle(700e8);

        assertLt(lending.healthFactor(user), 1e18);

        uint256 debtToRepay = lending.maxLiquidatableDebt(user);
        assertEq(debtToRepay, 750e6);

        uint256 collateralAmountToSeize = lending.collateralToSeize(debtToRepay);

        assertEq(collateralAmountToSeize, 1.125 ether);
        assertGt(collateralAmountToSeize, lending.collateralOf(user));

        address liquidator = address(0x1002);
        mockUSDC.mint(liquidator, debtToRepay);

        vm.startPrank(liquidator);
        mockUSDC.approve(address(lending), debtToRepay);

        vm.expectRevert(
            abi.encodeWithSelector(
                SimpleLendingPool.SeizeMoreThanBorrowerOwns.selector, collateralAmountToSeize, 1 ether
            )
        );

        lending.liquidate(user, debtToRepay);

        vm.stopPrank();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);
        assertEq(lending.totalDebt(), 1500e6);
    }

    function test_liquidate_revertsWhenInsufficientLiquidatorFundsAllowanceRollback() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        _setLatestPriceOracle(1800e8);

        address liquidator = address(0x1002);
        mockUSDC.mint(liquidator, 1000e6);

        vm.startPrank(liquidator);
        mockUSDC.approve(address(lending), 749e6);

        vm.expectRevert(); //AllowanceIsInsufficient
        lending.liquidate(user, 750e6);
        vm.stopPrank();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);
        assertEq(lending.totalDebt(), 1500e6);
        assertEq(lending.healthFactor(user), 960_000_000_000_000_000);
    }

    function test_liquidate_revertsWhenDebtReductionTooSmall() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1500e6);

        _setLatestPriceOracle(1800e8);

        address liquidator = address(0x1002);
        mockUSDC.mint(liquidator, 1000e6);

        skip(365 days);
        _setLatestPriceOracle(1800e8);

        vm.startPrank(liquidator);
        mockUSDC.approve(address(lending), 1000e6);

        vm.expectRevert(abi.encodeWithSelector(SimpleLendingPool.DebtReductionTooSmall.selector, 1));
        lending.liquidate(user, 1);
        vm.stopPrank();

        assertEq(lending.collateralOf(user), 1 ether);
        assertEq(lending.debtOf(user), 1541.25e6);
        assertEq(lending.healthFactor(user), 934_306_569_343_065_693);
    }

    function test_utilization_borrowRate_lifecycle() public {
        _fundsPool();
        _setLatestPriceOracle(int256(2000e8));

        assertEq(lending.collateralValue(user), 0);
        assertEq(lending.maxBorrow(user), 0);
        assertEq(lending.totalDebt(), 0);
        assertEq(lending.utilization(), 0);

        vm.startPrank(user);
        mockWETH.approve(address(lending), 6 ether);
        lending.supplyCollateral(6 ether);
        lending.borrow(1500e6);

        assertEq(lending.totalDebt(), 1500e6);
        assertEq(lending.utilization(), 0.15e18);
        assertEq(lending.currentBorrowRate(), 0.0275e18);

        lending.borrow(6500e6);

        assertEq(lending.collateralValue(user), 12_000e18); // 1 ether * wethPrice
        assertEq(lending.maxBorrow(user), 9000e6); // collateralValue * LTV => wad to debt token units

        assertEq(lending.totalDebt(), 8000e6);
        assertEq(lending.borrowIndex(), 1e18);
        assertEq(lending.lastInterestUpdate(), block.timestamp);

        assertEq(lending.utilization(), 0.8e18);
        assertEq(lending.currentBorrowRate(), 0.06e18);

        lending.accrueInterest();
        assertEq(lending.borrowIndex(), 1e18);
        assertEq(lending.lastInterestUpdate(), block.timestamp);

        uint256 expectedTimestamp = block.timestamp + 365 days;

        skip(365 days);

        lending.accrueInterest();
        assertEq(lending.borrowIndex(), 1.06e18);
        assertEq(lending.lastInterestUpdate(), expectedTimestamp);
        assertEq(lending.utilization(), 809_160_305_343_511_450);
        assertEq(lending.currentBorrowRate(), 94_351_145_038_167_937);
        assertEq(lending.totalDebt(), 8480e6); // scaled already

        // pool funds = 10_000 USDC
        // borrow = 1_500
        // available = 8_500

        // U = 15%
        // rate = 2.75%

        // then debt = 8_000
        // available = 2_000

        // U = 80%
        // rate = 6%

        // + 1 year
        // borrowIndex = 1.06

        // =>
        // U = 809_160_305_343_511_450
        // rate ~ 9.4%
        // totalDebt = 8480e6

        vm.stopPrank();
    }

    function test_accrueInterest_updatesBorrowIndex() public {
        _fundsPool();
        _setLatestPriceOracle(int256(2000e8));

        vm.startPrank(user);
        mockWETH.approve(address(lending), 6 ether);
        lending.supplyCollateral(6 ether);
        lending.borrow(8000e6);

        assertEq(lending.utilization(), 0.8e18);

        assertEq(lending.borrowIndex(), 1e18);

        uint256 expectedTimestamp = block.timestamp + 365 days;

        skip(365 days);

        lending.accrueInterest();
        assertEq(lending.borrowIndex(), 1.06e18);

        vm.stopPrank();
    }

    function test_virtual_debt_grows_without_storage_update() public {
        _fundsPool();
        _setLatestPriceOracle(int256(2000e8));

        vm.startPrank(user);
        mockWETH.approve(address(lending), 6 ether);
        lending.supplyCollateral(6 ether);
        lending.borrow(8000e6);
        vm.stopPrank();

        assertEq(lending.borrowIndex(), 1e18);
        assertEq(lending.currentBorrowIndex(), 1e18);

        assertEq(lending.totalDebt(), 8000e6);
        assertEq(lending.debtOf(user), 8000e6);

        skip(365 days);

        assertEq(lending.borrowIndex(), 1e18);
        assertEq(lending.currentBorrowIndex(), 1.06e18);

        assertEq(lending.debtOf(user), 8480e6);
        assertEq(lending.totalDebt(), 8480e6);
    }

    function test_previewBorrowIndex() public {
        _fundsPool();
        _setLatestPriceOracle(int256(2000e8));

        vm.startPrank(user);
        mockWETH.approve(address(lending), 6 ether);
        lending.supplyCollateral(6 ether);
        lending.borrow(8000e6);
        vm.stopPrank();

        assertEq(lending.borrowIndex(), 1e18);
        assertEq(lending.currentBorrowIndex(), 1e18);

        assertEq(lending.totalDebt(), 8000e6);
        assertEq(lending.debtOf(user), 8000e6);

        skip(30 days);

        uint256 previewIndex = lending.currentBorrowIndex();

        lending.accrueInterest();

        assertEq(lending.borrowIndex(), previewIndex); //1004931506849315069
        assertEq(lending.currentBorrowIndex(), previewIndex);
        assertEq(lending.lastInterestUpdate(), block.timestamp);
    }

    function test_healthFactor_interest_alone_reduces_health_factor() public {
        _openMaxBorrowPosition();

        assertEq(lending.collateralValue(user), 2000e18);
        assertEq(lending.maxBorrow(user), 1500e6);
        assertEq(lending.debtOf(user), 1500e6);

        assertEq(lending.healthFactor(user), 1_066_666_666_666_666_666);

        uint256 hfBefore = lending.healthFactor(user);

        skip(365 days);

        _setLatestPriceOracle(int256(2000e8));

        assertEq(lending.debtOf(user), 1541.25e6);

        uint256 hfAfter = lending.healthFactor(user);

        assertLt(hfAfter, hfBefore); //1_038_118_410_381_184_103 < 1_066_666_666_666_666_666

        skip(2 * 365 days);

        _setLatestPriceOracle(int256(2000e8));

        assertEq(lending.debtOf(user), 1623.75e6);

        hfAfter = lending.healthFactor(user);

        assertLt(hfAfter, 1e18); // liquidatable
    }

    function test_new_borrow_does_not_receive_historical_interest() public {
        _fundsPool();
        _setLatestPriceOracle(int256(2000e8));

        vm.startPrank(user);
        mockWETH.approve(address(lending), 1 ether);
        lending.supplyCollateral(1 ether);
        lending.borrow(1000e6);
        vm.stopPrank();

        assertEq(lending.collateralValue(user), 2000e18);
        assertEq(lending.maxBorrow(user), 1500e6);
        assertEq(lending.debtOf(user), 1000e6);

        skip(60 days);
        _setLatestPriceOracle(int256(2000e8));

        uint256 accruedDebtBeforeSecondBorrow = lending.debtOf(user);

        vm.prank(user);
        lending.borrow(200e6);

        uint256 debtAfter = lending.debtOf(user);

        assertGe(debtAfter, accruedDebtBeforeSecondBorrow + 200e6);
    }
}
