// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { SimpleLendingPool } from "src/labs/lending/SimpleLendingPool.sol";
import { PushOracleAdapter } from "src/labs/oracles/PushOracleAdapter.sol";
import { MockAggregatorV3 } from "test/mocks/MockAggregatorV3.sol";
import { TokenTransfer, IERC20 } from "src/common/token/TokenTransfer.sol";
import { MockFeeOnTransferERC20 } from "test/mocks/MockFeeOnTransferERC20.sol";
import { MockWETH } from "test/mocks/MockWETH.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";

contract SimpleLendingPoolTest is Test {
    SimpleLendingPool lending;
    PushOracleAdapter adapter;
    MockAggregatorV3 feed;
    MockWETH mockWETH;
    MockUSDC mockUSDC;

    address user = address(0x1001);

    event Supplied(address indexed user, address indexed collateralToken, uint256 amount);
    event Borrowed(address indexed user, address indexed debtToken, uint256 amount);

    function setUp() public {
        feed = new MockAggregatorV3(uint256(1), uint8(8), "MockAggregatorV3::ETH/USD");
        adapter = new PushOracleAdapter(address(feed), bytes32("ETH"), bytes32("USD"), 1 hours);

        mockWETH = new MockWETH();
        mockUSDC = new MockUSDC();

        mockWETH.mint(user, 10 ether);

        lending = new SimpleLendingPool(address(mockWETH), address(mockUSDC), address(adapter));
    }

    function test_deployment_configuration() public {
        assertEq(address(lending.collateralToken()), address(mockWETH));
        assertEq(address(lending.debtToken()), address(mockUSDC));
        assertEq(address(lending.oracle()), address(adapter));
    }

    function test_deployment_configuration_reverts() public {
        vm.expectRevert(SimpleLendingPool.ZeroAddress.selector);
        new SimpleLendingPool(address(0), address(mockUSDC), address(adapter));

        vm.expectRevert(SimpleLendingPool.ZeroAddress.selector);
        new SimpleLendingPool(address(mockWETH), address(0), address(adapter));

        vm.expectRevert(SimpleLendingPool.ZeroAddress.selector);
        new SimpleLendingPool(address(mockWETH), address(mockUSDC), address(0));
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

        SimpleLendingPool lending2 = new SimpleLendingPool(address(feeToken), address(mockUSDC), address(adapter));

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
}
