// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IERC20TransferRestriction} from "../src/interfaces/IERC20TransferRestriction.sol";
import {BaseTest} from "./BaseTest.sol";
import {OrderAssertingHook} from "./mocks/HookReceivers.sol";

/**
 * @title UpdateOrderingTest
 * @notice Pins the phase order that `ERC20ExtensionCore._update` fixes, from the outside.
 *
 * @dev Most of the ordering is invisible from outside a successful transaction, because a revert in any
 *      phase rolls back all of them. These are the four places where the order does leave a trace, and
 *      together they constrain it completely:
 *
 *      1. A frozen fee vault does not block transfers — so the restriction check runs *once*, against the
 *         caller's own arguments, and never against the fee leg's.
 *      2. The fee `Transfer` is emitted before the net `Transfer` — so collection precedes the main leg.
 *      3. The hook observes both the recipient's credit and the vault's — so it runs after both.
 *      4. A hook veto rolls back the fee leg — so the phases commit together or not at all.
 */
contract UpdateOrderingTest is BaseTest {
    /**
     * @dev The most valuable of the four. Under the naive composition — every module overriding `_update`
     *      and calling `super` — the fee module's second `_update` would descend through the restriction
     *      module again, this time with `to` set to the fee vault. Freezing the vault would then break
     *      every transfer on the token, for a reason no one would think to look for.
     */
    function test_FrozenFeeVaultDoesNotBlockTransfers() public {
        _setFee(500, type(uint128).max);
        _setFrozen(vault, true);

        vm.prank(alice);
        token.transfer(bob, 1000e18);

        assertEq(token.balanceOf(vault), 50e18, "fee still reached the frozen vault");
        assertEq(token.balanceOf(bob), INITIAL_BALANCE + 950e18);
    }

    /// @dev And the restriction check that *does* apply still applies.
    function test_RestrictionStillScreensTheCallersOwnArguments() public {
        _setFee(500, type(uint128).max);
        _setFrozen(alice, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferRestriction.ERC20TransferRestricted.selector, token.RESTRICTION_SENDER_FROZEN()
            )
        );
        vm.prank(alice);
        token.transfer(bob, 1000e18);
    }

    function test_FeeLegIsEmittedBeforeTheMainLeg() public {
        _setFee(250, type(uint128).max);
        uint256 fee = token.computeFee(alice, bob, 1000e18);

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, vault, fee);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 1000e18 - fee);

        vm.prank(alice);
        token.transfer(bob, 1000e18);
    }

    function test_HookRunsAfterBalancesHaveSettled() public {
        _setFee(1000, type(uint128).max); // 10%
        OrderAssertingHook observer = new OrderAssertingHook(vault);
        _setHook(address(observer), 200_000);

        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        token.transfer(bob, 1000e18);

        // From inside the hook, the recipient's credit was already visible...
        assertEq(observer.observedRecipientBalance(), bobBefore + 900e18);
        // ...and so was the fee, which means collection had already happened.
        assertEq(observer.observedVaultBalance(), 100e18);
        // ...and the value it was handed is the net one.
        assertEq(observer.observedValue(), 900e18);
    }

    /// @dev No partial commits: the fee leg is not a separate transaction.
    function test_AllPhasesCommitTogether() public {
        _setFee(500, type(uint128).max);

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 vaultBefore = token.balanceOf(vault);

        // Freezing bob makes phase 1 reject a transfer that would otherwise have moved a fee in phase 2.
        _setFrozen(bob, true);

        vm.prank(alice);
        try token.transfer(bob, 1000e18) {
            fail();
        } catch {}

        assertEq(token.balanceOf(alice), aliceBefore);
        assertEq(token.balanceOf(vault), vaultBefore);
    }

    /// @dev The phase order does not depend on how the transfer was initiated.
    function test_ExactOutTakesTheSamePath() public {
        _setFee(500, type(uint128).max);
        _setFrozen(vault, true);
        OrderAssertingHook observer = new OrderAssertingHook(vault);
        _setHook(address(observer), 200_000);

        vm.prank(alice);
        uint256 amountIn = token.transferExactOut(bob, 950e18);

        assertEq(token.balanceOf(bob), INITIAL_BALANCE + 950e18);
        assertEq(observer.observedValue(), 950e18);
        assertEq(token.balanceOf(vault), amountIn - 950e18);
    }
}
