// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "@forge-std/Test.sol";
import { IndexedLendingPool } from "src/labs/lending/IndexedLendingPool.sol";
import { ScaledSupplyToken } from "src/labs/lending/tokens/ScaledSupplyToken.sol";
import { ScaledDebtToken } from "src/labs/lending/tokens/ScaledDebtToken.sol";
import { MockUSDC } from "test/mocks/MockUSDC.sol";

contract IndexedLendingPoolTest is Test {
    IndexedLendingPool pool;
    MockUSDC usdc;

    address alice = address(0x1001);
    address bob = address(0x1002);
    address borrower = address(0x1003);

    event Supplied(address indexed caller, address indexed onBehalfOf, uint256 actualAmount, uint256 scaledAmount);
    event Withdrawn(address indexed user, address indexed to, uint256 actualAmount, uint256 scaledAmount);
    event Borrowed(address indexed borrower, address indexed recipient, uint256 actualAmount, uint256 scaledAmount);
    event Repayed(address indexed payer, address indexed onBehalfOf, uint256 actualAmount, uint256 scaledAmount);

    function setUp() public {
        usdc = new MockUSDC();
        pool = new IndexedLendingPool(address(usdc));
    }

    function test_constructor_configuration() public {
        assertEq(address(pool.UNDERLYING()), address(usdc));

        assertEq(pool.currentLiquidityIndex(), 1e18);
        assertEq(pool.currentBorrowIndex(), 1e18);

        ScaledSupplyToken supplyToken = pool.SUPPLY_TOKEN();
        ScaledDebtToken debtToken = pool.DEBT_TOKEN();

        assertEq(supplyToken.POOL(), address(pool));
        assertEq(debtToken.POOL(), address(pool));

        assertEq(supplyToken.decimals(), 6);
        assertEq(debtToken.decimals(), 6);

        assertEq(supplyToken.symbol(), "aUSDC");
        assertEq(debtToken.symbol(), "vdUSDC");
    }

    function test_constructor_revertsWhenUnderlyingIsZero() public {
        vm.expectRevert(IndexedLendingPool.ZeroAddress.selector);
        new IndexedLendingPool(address(0));
    }

    function test_constructor_revertsWhenInvalidUnderlying() public {
        address nonContract = address(0xBEEF);

        assertEq(nonContract.code.length, 0);

        vm.expectRevert(abi.encodeWithSelector(IndexedLendingPool.InvalidUnderlying.selector, nonContract));
        new IndexedLendingPool(nonContract);
    }

    function test_positionTokenNames() public {
        assertEq(pool.SUPPLY_TOKEN().name(), "Indexed Supply USDC");

        assertEq(pool.DEBT_TOKEN().name(), "Variable Debt USDC");
    }

    function test_positionTokens_rejectDirectMint() public {
        ScaledSupplyToken supplyToken = pool.SUPPLY_TOKEN();

        ScaledDebtToken debtToken = pool.DEBT_TOKEN();

        vm.expectRevert(abi.encodeWithSelector(ScaledSupplyToken.OnlyPool.selector, address(this)));
        supplyToken.mintScaled(address(this), 1000e6);

        vm.expectRevert(abi.encodeWithSelector(ScaledDebtToken.OnlyPool.selector, address(this)));
        debtToken.mintScaled(address(this), 1000e6);
    }

    function test_supply() public {
        usdc.mint(alice, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        vm.expectEmit(true, true, false, true);
        emit Supplied(alice, alice, 1000e6, 1000e6);
        pool.supply(1000e6, alice);
        vm.stopPrank();

        ScaledSupplyToken supplyToken = pool.SUPPLY_TOKEN();

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 1000e6);

        assertEq(pool.availableLiquidity(), 1000e6);

        assertEq(supplyToken.scaledBalanceOf(alice), 1000e6);
        assertEq(supplyToken.balanceOf(alice), 1000e6);

        assertEq(supplyToken.totalSupply(), 1000e6);
        assertEq(pool.DEBT_TOKEN().totalSupply(), 0);

        assertEq(pool.availableLiquidity(), usdc.balanceOf(address(pool)));
    }

    function test_supply_onBehalfOf() public {
        usdc.mint(alice, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        vm.expectEmit(true, true, false, true);
        emit Supplied(alice, bob, 1000e6, 1000e6);
        pool.supply(1000e6, bob);
        vm.stopPrank();

        ScaledSupplyToken supplyToken = pool.SUPPLY_TOKEN();

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 1000e6);

        assertEq(pool.availableLiquidity(), 1000e6);

        assertEq(supplyToken.scaledBalanceOf(alice), 0e6);
        assertEq(supplyToken.balanceOf(alice), 0e6);

        assertEq(supplyToken.scaledBalanceOf(bob), 1000e6);
        assertEq(supplyToken.balanceOf(bob), 1000e6);

        assertEq(supplyToken.totalSupply(), 1000e6);
        assertEq(pool.DEBT_TOKEN().totalSupply(), 0);

        assertEq(pool.availableLiquidity(), usdc.balanceOf(address(pool)));
    }

    function test_supply_revertsWhenZeroAddress() public {
        usdc.mint(alice, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        vm.expectRevert(IndexedLendingPool.ZeroAddress.selector);
        pool.supply(1000e6, address(0));
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(pool.SUPPLY_TOKEN().balanceOf(alice), 0e6);
    }

    function test_supply_revertsWhenZeroAmount() public {
        usdc.mint(alice, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        vm.expectRevert(IndexedLendingPool.ZeroAmount.selector);
        pool.supply(0e6, address(alice));
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(pool.SUPPLY_TOKEN().balanceOf(alice), 0e6);
    }

    function test_supply_revertsWhenInsufficientAllowance() public {
        usdc.mint(alice, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 100e6);

        vm.expectRevert(); //ERC20InsufficientAllowance
        pool.supply(101e6, address(alice));
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(pool.SUPPLY_TOKEN().balanceOf(alice), 0e6);
    }

    function test_supply_revertsWhenInsufficientUnderlying() public {
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);

        vm.expectRevert(); //ERC20InsufficientBalance
        pool.supply(1000e6, address(alice));
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(pool.SUPPLY_TOKEN().balanceOf(alice), 0e6);
    }

    function test_withdraw_partial() public {
        usdc.mint(alice, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.supply(1000e6, alice);

        vm.expectEmit(true, true, false, true);
        emit Withdrawn(alice, alice, 400e6, 400e6);
        pool.withdraw(400e6, alice);
        vm.stopPrank();

        ScaledSupplyToken supplyToken = pool.SUPPLY_TOKEN();

        assertEq(usdc.balanceOf(alice), 400e6);
        assertEq(usdc.balanceOf(address(pool)), 600e6);

        assertEq(pool.availableLiquidity(), 600e6);

        assertEq(supplyToken.scaledBalanceOf(alice), 600e6);
        assertEq(supplyToken.balanceOf(alice), 600e6);

        assertEq(supplyToken.totalSupply(), 600e6);
        assertEq(pool.DEBT_TOKEN().totalSupply(), 0);

        assertEq(pool.availableLiquidity(), usdc.balanceOf(address(pool)));
    }

    function test_withdraw_full() public {
        usdc.mint(alice, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.supply(1000e6, alice);

        vm.expectEmit(true, true, false, true);
        emit Withdrawn(alice, alice, 1000e6, 1000e6);
        uint256 withdrawn = pool.withdraw(1000e6, alice);
        vm.stopPrank();

        assertEq(withdrawn, 1000e6);

        ScaledSupplyToken supplyToken = pool.SUPPLY_TOKEN();

        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(usdc.balanceOf(address(pool)), 0e6);

        assertEq(pool.availableLiquidity(), 0e6);

        assertEq(supplyToken.scaledBalanceOf(alice), 0e6);
        assertEq(supplyToken.balanceOf(alice), 0e6);

        assertEq(supplyToken.totalSupply(), 0e6);
        assertEq(pool.DEBT_TOKEN().totalSupply(), 0);
    }

    function test_withdraw_toDifferentRecipient() public {
        usdc.mint(alice, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.supply(1000e6, alice);

        vm.expectEmit(true, true, false, true);
        emit Withdrawn(alice, bob, 400e6, 400e6);
        pool.withdraw(400e6, bob);
        vm.stopPrank();

        ScaledSupplyToken supplyToken = pool.SUPPLY_TOKEN();

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(bob), 400e6);
        assertEq(usdc.balanceOf(address(pool)), 600e6);

        assertEq(pool.availableLiquidity(), 600e6);

        assertEq(supplyToken.scaledBalanceOf(alice), 600e6);
        assertEq(supplyToken.balanceOf(alice), 600e6);

        assertEq(supplyToken.totalSupply(), 600e6);
        assertEq(pool.DEBT_TOKEN().totalSupply(), 0);

        assertEq(pool.availableLiquidity(), usdc.balanceOf(address(pool)));
    }

    function test_withdraw_revertsWhenZeroAmount() public {
        usdc.mint(alice, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.supply(1000e6, alice);

        vm.expectRevert(IndexedLendingPool.ZeroAmount.selector);
        pool.withdraw(0e6, bob);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 1000e6);
    }

    function test_withdraw_revertsWhenZeroAddress() public {
        usdc.mint(alice, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.supply(1000e6, alice);

        vm.expectRevert(IndexedLendingPool.ZeroAddress.selector);
        pool.withdraw(400e6, address(0));
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 1000e6);
    }

    function test_withdraw_revertsWhenWithdrawExceedsSupply() public {
        usdc.mint(alice, 1000e6);

        vm.startPrank(alice);
        usdc.approve(address(pool), 1000e6);
        pool.supply(1000e6, alice);

        vm.expectRevert(abi.encodeWithSelector(IndexedLendingPool.WithdrawExceedsSupply.selector, 1001e6, 1000e6));
        pool.withdraw(1001e6, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 1000e6);
    }

    function test_withdraw_revertsWhenInsufficientLiquidity() public {
        _supplyAlice(1000e6);

        vm.prank(borrower);
        pool.borrow(800e6, borrower);

        assertEq(pool.SUPPLY_TOKEN().balanceOf(alice), 1000e6);

        assertEq(pool.availableLiquidity(), 200e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IndexedLendingPool.InsufficientLiquidity.selector, 300e6, 200e6));

        pool.withdraw(300e6, alice);

        // Failed withdrawal preserves all accounting
        assertEq(pool.SUPPLY_TOKEN().balanceOf(alice), 1000e6);

        assertEq(pool.availableLiquidity(), 200e6);
        assertEq(usdc.balanceOf(address(pool)), 200e6);
        assertEq(pool.DEBT_TOKEN().balanceOf(borrower), 800e6);
    }

    function _supplyAlice(uint256 amount) internal {
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(pool), amount);
        pool.supply(amount, alice);
        vm.stopPrank();
    }

    function test_borrow() public {
        _supplyAlice(1000e6);

        vm.prank(borrower);
        vm.expectEmit(true, true, false, true);
        emit Borrowed(borrower, borrower, 400e6, 400e6);
        pool.borrow(400e6, borrower);

        ScaledSupplyToken supplyToken = pool.SUPPLY_TOKEN();

        ScaledDebtToken debtToken = pool.DEBT_TOKEN();

        // Cash flow
        assertEq(usdc.balanceOf(borrower), 400e6);
        assertEq(usdc.balanceOf(address(pool)), 600e6);
        assertEq(pool.availableLiquidity(), 600e6);

        // Supplier position remains unchanged
        assertEq(supplyToken.balanceOf(alice), 1000e6);
        assertEq(supplyToken.totalSupply(), 1000e6);

        // Borrower owns the debt
        assertEq(debtToken.scaledBalanceOf(borrower), 400e6);

        assertEq(debtToken.balanceOf(borrower), 400e6);
        assertEq(debtToken.totalSupply(), 400e6);

        // Cash accounting
        assertEq(pool.availableLiquidity(), usdc.balanceOf(address(pool)));

        // At index = 1 and before interest:
        // supplier claims = liquid cash + borrower receivable
        assertEq(supplyToken.totalSupply(), pool.availableLiquidity() + debtToken.totalSupply());
    }

    function test_borrow_toDifferentRecipient() public {
        _supplyAlice(1000e6);

        vm.prank(borrower);
        vm.expectEmit(true, true, false, true);
        emit Borrowed(borrower, bob, 400e6, 400e6);
        pool.borrow(400e6, bob);

        assertEq(usdc.balanceOf(bob), 400e6);
        assertEq(usdc.balanceOf(borrower), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 600e6);
        assertEq(pool.availableLiquidity(), 600e6);

        // Recipient gets cash, caller gets debt
        assertEq(pool.DEBT_TOKEN().balanceOf(bob), 0e6);
        assertEq(pool.DEBT_TOKEN().balanceOf(borrower), 400e6);
    }

    function test_borrow_revertsWhenZeroAmount() public {
        vm.prank(borrower);
        vm.expectRevert(IndexedLendingPool.ZeroAmount.selector);
        pool.borrow(0, borrower);
    }

    function test_borrow_revertsWhenRecipientIsZero() public {
        vm.prank(borrower);
        vm.expectRevert(IndexedLendingPool.ZeroAddress.selector);
        pool.borrow(100e6, address(0));
    }

    function test_borrow_revertsWhenInsufficientLiquidity() public {
        _supplyAlice(1000e6);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IndexedLendingPool.InsufficientLiquidity.selector, 1001e6, 1000e6));

        pool.borrow(1001e6, borrower);

        assertEq(pool.availableLiquidity(), 1000e6);
        assertEq(usdc.balanceOf(address(pool)), 1000e6);
        assertEq(pool.DEBT_TOKEN().balanceOf(borrower), 0);
    }

    function test_repay() public {
        _supplyAlice(1000e6);

        vm.startPrank(borrower);
        pool.borrow(500e6, borrower);

        assertEq(usdc.balanceOf(borrower), 500e6);
        assertEq(usdc.balanceOf(address(pool)), 500e6);
        assertEq(pool.availableLiquidity(), 500e6);

        usdc.approve(address(pool), 300e6);

        vm.expectEmit(true, true, false, true);
        emit Repayed(borrower, borrower, 300e6, 300e6);
        pool.repay(300e6, borrower);

        vm.stopPrank();

        ScaledSupplyToken supplyToken = pool.SUPPLY_TOKEN();
        ScaledDebtToken debtToken = pool.DEBT_TOKEN();

        assertEq(usdc.balanceOf(borrower), 200e6);
        assertEq(usdc.balanceOf(address(pool)), 800e6);
        assertEq(pool.availableLiquidity(), 800e6);

        assertEq(debtToken.scaledBalanceOf(borrower), 200e6);

        assertEq(debtToken.balanceOf(borrower), 200e6);
        assertEq(debtToken.totalSupply(), 200e6);

        assertEq(pool.availableLiquidity(), usdc.balanceOf(address(pool)));

        assertEq(supplyToken.totalSupply(), pool.availableLiquidity() + debtToken.totalSupply());
    }

    function test_repay_onBehalfOf() public {
        _supplyAlice(1000e6);

        vm.prank(borrower);
        pool.borrow(400e6, bob);

        assertEq(usdc.balanceOf(bob), 400e6);
        assertEq(usdc.balanceOf(borrower), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 600e6);
        assertEq(pool.availableLiquidity(), 600e6);

        assertEq(pool.DEBT_TOKEN().balanceOf(bob), 0e6);
        assertEq(pool.DEBT_TOKEN().balanceOf(borrower), 400e6);

        vm.startPrank(bob);
        usdc.approve(address(pool), 300e6);
        pool.repay(300e6, borrower);
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), 100e6);
        assertEq(usdc.balanceOf(borrower), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 900e6);
        assertEq(pool.availableLiquidity(), 900e6);

        assertEq(pool.DEBT_TOKEN().balanceOf(borrower), 100e6);
        assertEq(pool.DEBT_TOKEN().totalSupply(), 100e6);

        assertEq(pool.availableLiquidity(), usdc.balanceOf(address(pool)));

        assertEq(pool.SUPPLY_TOKEN().totalSupply(), pool.availableLiquidity() + pool.DEBT_TOKEN().totalSupply());
    }

    function test_repay_revertsWhenZeroAmount() public {
        vm.prank(borrower);
        vm.expectRevert(IndexedLendingPool.ZeroAmount.selector);
        pool.repay(0, borrower);
    }

    function test_repay_revertsWhenRecipientIsZero() public {
        vm.prank(borrower);
        vm.expectRevert(IndexedLendingPool.ZeroAddress.selector);
        pool.repay(100e6, address(0));
    }

    function test_repay_revertsWhenCurrentDebtExceeded() public {
        _supplyAlice(1000e6);

        vm.prank(borrower);
        pool.borrow(400e6, bob);

        assertEq(usdc.balanceOf(bob), 400e6);
        assertEq(usdc.balanceOf(borrower), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 600e6);
        assertEq(pool.availableLiquidity(), 600e6);

        vm.prank(bob);
        usdc.approve(address(pool), 401e6);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IndexedLendingPool.CurrentDebtExceeded.selector, 401e6, 400e6));
        pool.repay(401e6, borrower);

        assertEq(usdc.balanceOf(bob), 400e6);
        assertEq(usdc.balanceOf(borrower), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 600e6);
        assertEq(pool.availableLiquidity(), 600e6);
    }

    function test_repay_full() public {
        _supplyAlice(1000e6);

        vm.startPrank(borrower);
        pool.borrow(500e6, borrower);

        assertEq(usdc.balanceOf(borrower), 500e6);
        assertEq(usdc.balanceOf(address(pool)), 500e6);
        assertEq(pool.availableLiquidity(), 500e6);

        usdc.approve(address(pool), 500e6);
        pool.repay(500e6, borrower);
        vm.stopPrank();

        assertEq(usdc.balanceOf(borrower), 0e6);
        assertEq(usdc.balanceOf(address(pool)), 1000e6);
        assertEq(pool.availableLiquidity(), 1000e6);

        assertEq(pool.DEBT_TOKEN().balanceOf(borrower), 0e6);
        assertEq(pool.DEBT_TOKEN().totalSupply(), 0e6);

        assertEq(pool.availableLiquidity(), usdc.balanceOf(address(pool)));

        assertEq(pool.SUPPLY_TOKEN().totalSupply(), pool.availableLiquidity() + pool.DEBT_TOKEN().totalSupply());
    }
}
