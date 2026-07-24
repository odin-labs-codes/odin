// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "./BaseTest.sol";
import {OrderAssertingHook, RejectingHook} from "./mocks/HookReceivers.sol";

/// @dev The phase order lives in one function in `ERC20ExtensionCore` and no module can change it. These
///      tests pin the order from the outside, so a refactor that moved a phase would fail here rather than
///      in whichever module happened to notice first.
contract UpdateOrderingTest is BaseTest {
    function test_RestrictionRunsBeforeAnyFeeMoves() public {
        _setFee(100, type(uint256).max);
        _setPaused(true);

        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 100e18);

        // A rejected transfer must not have moved a fee.
        assertEq(token.balanceOf(vault), 0);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
    }

    function test_AFrozenSenderIsScreenedBeforeTheFeeToo() public {
        _setFee(100, type(uint256).max);
        _setFrozen(alice, true);

        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 100e18);

        assertEq(token.balanceOf(vault), 0);
    }

    function test_TheFeeLegIsItsOwnTransferBeforeTheMainOne() public {
        _setFee(100, type(uint256).max);

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, vault, 1e18);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 99e18);

        vm.prank(alice);
        token.transfer(bob, 100e18);
    }

    function test_TheHookRunsLastAndSeesEverythingSettled() public {
        OrderAssertingHook observer = new OrderAssertingHook(vault);
        _setFee(100, type(uint256).max);
        _setHook(address(observer), 500_000);

        vm.prank(alice);
        token.transfer(bob, 100e18);

        // By phase 4 the fee leg and the main leg have both landed.
        assertEq(observer.vaultBalanceAtCall(), 1e18);
        assertEq(observer.senderBalanceAtCall(), INITIAL_BALANCE - 100e18);
        assertEq(observer.recipientBalanceAtCall(), INITIAL_BALANCE + 99e18);
    }

    function test_ARejectingHookUndoesEveryEarlierPhase() public {
        RejectingHook rejecting = new RejectingHook();
        _setFee(100, type(uint256).max);
        _setHook(address(rejecting), 100_000);

        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 100e18);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE);
        assertEq(token.balanceOf(vault), 0);
    }

    function test_ASenderHoldingExactlyTheAmountSurvivesBothLegs() public {
        _setFee(1_000, type(uint256).max);

        vm.prank(admin);
        token.mint(carol, 100e18);

        vm.prank(carol);
        token.transfer(bob, 100e18);

        assertEq(token.balanceOf(carol), 0);
        assertEq(token.balanceOf(vault), 10e18);
    }
}
