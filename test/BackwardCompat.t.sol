// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "./BaseTest.sol";
import {RecordingHook} from "./mocks/HookReceivers.sol";

/**
 * @title BackwardCompatTest
 * @notice The regression that matters most: with every extension installed, and the ones that can be
 *         switched on switched on, the ERC-20 surface still behaves exactly as an integrator who has never
 *         heard of this framework expects.
 *
 * @dev Run in two configurations.
 *
 *      With the fee at zero, the token must be *indistinguishable* from a plain ERC-20 — same return
 *      values, same events, same reverts, same arithmetic. The extensions are installed and the hook is
 *      live; none of that may leak into the standard surface.
 *
 *      With the fee on, exactly one thing changes — the recipient's credit — and it changes in the way the
 *      declaration says it does. Everything else, including the debit from the sender, the return value,
 *      the allowance arithmetic and total supply, stays put.
 */
contract BackwardCompatTest is BaseTest {
    RecordingHook internal hook;

    function setUp() public override {
        super.setUp();
        hook = new RecordingHook();
        // The recorder writes five storage slots, so it genuinely needs more than a nominal budget.
        _setHook(address(hook), 200_000);
        _setFrozen(carol, false);
    }

    // -----------------------------------------------------------------------------------------------
    // Metadata and supply
    // -----------------------------------------------------------------------------------------------

    function test_NameSymbolDecimalsUnchanged() public view {
        assertEq(token.name(), "Extended Token");
        assertEq(token.symbol(), "EXT");
        assertEq(token.decimals(), 18);
    }

    function test_TotalSupplyIsSumOfMints() public view {
        assertEq(token.totalSupply(), INITIAL_BALANCE * 2);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE);
    }

    // -----------------------------------------------------------------------------------------------
    // Fee off: indistinguishable from a plain ERC-20
    // -----------------------------------------------------------------------------------------------

    function test_TransferReturnsTrueAndEmitsExactlyOneEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 100e18);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 100e18));

        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 100e18);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE + 100e18);
    }

    function test_ZeroValueTransferSucceedsAndEmits() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
    }

    function test_SelfTransferIsANoOp() public {
        vm.prank(alice);
        token.transfer(alice, 500e18);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
    }

    function test_ApproveAndTransferFrom() public {
        vm.prank(alice);
        assertTrue(token.approve(bob, 300e18));
        assertEq(token.allowance(alice, bob), 300e18);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 200e18));

        assertEq(token.allowance(alice, bob), 100e18);
        assertEq(token.balanceOf(carol), 200e18);
    }

    function test_InfiniteAllowanceIsNotDecremented() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, carol, 1000e18);

        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_RevertWhen_TransferExceedsBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, alice, INITIAL_BALANCE, INITIAL_BALANCE + 1
            )
        );
        vm.prank(alice);
        token.transfer(bob, INITIAL_BALANCE + 1);
    }

    function test_RevertWhen_TransferFromExceedsAllowance() public {
        vm.prank(alice);
        token.approve(bob, 10e18);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 10e18, 11e18));
        vm.prank(bob);
        token.transferFrom(alice, carol, 11e18);
    }

    function test_RevertWhen_TransferToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), 1e18);
    }

    function test_RevertWhen_ApproveZeroAddressSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(alice);
        token.approve(address(0), 1e18);
    }

    // -----------------------------------------------------------------------------------------------
    // Fee on: only the declared difference appears
    // -----------------------------------------------------------------------------------------------

    function test_WithFee_SenderIsStillDebitedExactlyTheRequestedAmount() public {
        _setFee(100, type(uint128).max); // 1%

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(bob, 1000e18);

        // ERC-20's meaning of `transfer(to, amount)` is preserved on the sender's side, without exception.
        assertEq(before - token.balanceOf(alice), 1000e18);
    }

    function test_WithFee_TransferStillReturnsTrue() public {
        _setFee(100, type(uint128).max);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1000e18));
    }

    function test_WithFee_TotalSupplyIsUnchanged() public {
        _setFee(250, type(uint128).max);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.transfer(bob, 1000e18);

        assertEq(token.totalSupply(), supplyBefore);
    }

    function test_WithFee_BothLegsAreVisibleAsTransferEvents() public {
        _setFee(100, type(uint128).max);
        uint256 fee = token.computeFee(alice, bob, 1000e18);

        // The fee leg first, then the net leg: an indexer summing `Transfer` events sees value conserved.
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, vault, fee);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 1000e18 - fee);

        vm.prank(alice);
        token.transfer(bob, 1000e18);
    }

    function test_WithFee_AllowanceIsSpentOnTheGrossAmount() public {
        _setFee(100, type(uint128).max);

        vm.prank(alice);
        token.approve(bob, 1000e18);
        vm.prank(bob);
        token.transferFrom(alice, carol, 1000e18);

        // The spender moved 1000 out of alice, so 1000 of allowance is gone — the fee is not a discount.
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_WithFee_MintAndBurnAreNotCharged() public {
        _setFee(1000, type(uint128).max); // the maximum rate

        uint256 vaultBefore = token.balanceOf(vault);

        vm.startPrank(admin);
        token.mint(carol, 1000e18);
        assertEq(token.balanceOf(carol), 1000e18);

        token.burn(carol, 400e18);
        assertEq(token.balanceOf(carol), 600e18);
        vm.stopPrank();

        assertEq(token.balanceOf(vault), vaultBefore);
    }
}
