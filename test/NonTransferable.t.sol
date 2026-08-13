// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC20NonTransferable} from "../src/interfaces/IERC20NonTransferable.sol";
import {BehaviorFlags} from "../src/libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../src/libraries/ExtensionIds.sol";
import {Combo_MRN} from "./mocks/Combinations.sol";

/**
 * @title NonTransferableTest
 * @notice Soulbound behaviour, assembled alongside metadata and transfer restrictions.
 *
 * @dev This combination is the reason the module exists: a credential that cannot be traded, that carries
 *      its issuer's data on chain, and that the issuer can still freeze and burn.
 */
contract NonTransferableTest is Test {
    Combo_MRN internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new Combo_MRN("Soulbound", "SBT");
        token.mint(alice, 1000e18);
    }

    function test_TransferAlwaysReverts() public {
        vm.expectRevert(IERC20NonTransferable.ERC20TransfersNotSupported.selector);
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_TransferFromAlwaysReverts() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.expectRevert(IERC20NonTransferable.ERC20TransfersNotSupported.selector);
        vm.prank(bob);
        token.transferFrom(alice, bob, 1e18);
    }

    /// @dev Even a zero-value transfer is refused: the restriction is on the operation, not the amount.
    function test_ZeroValueTransferReverts() public {
        vm.expectRevert(IERC20NonTransferable.ERC20TransfersNotSupported.selector);
        vm.prank(alice);
        token.transfer(bob, 0);
    }

    /// @dev Self-transfers are refused too. Allowing them would be harmless but would make the rule
    ///      conditional, and a conditional rule is one an integrator has to read the source to learn.
    function test_SelfTransferReverts() public {
        vm.expectRevert(IERC20NonTransferable.ERC20TransfersNotSupported.selector);
        vm.prank(alice);
        token.transfer(alice, 1e18);
    }

    /// @dev Approvals still work. An allowance on a token that cannot move is inert, and removing it would
    ///      break wallets that approve before transferring.
    function test_ApproveStillWorks() public {
        vm.prank(alice);
        assertTrue(token.approve(bob, 500e18));
        assertEq(token.allowance(alice, bob), 500e18);
    }

    function test_MintAndBurnStillMoveSupply() public {
        token.mint(bob, 250e18);
        assertEq(token.balanceOf(bob), 250e18);

        token.burn(bob, 100e18);
        assertEq(token.balanceOf(bob), 150e18);
        assertEq(token.totalSupply(), 1000e18 + 150e18);
    }

    function test_ItSaysSo() public view {
        assertGt(token.behaviorFlags() & BehaviorFlags.NON_TRANSFERABLE, 0);
        assertTrue(token.hasExtension(ExtensionIds.NON_TRANSFERABLE));
        // And it never claims a fee it could not charge.
        assertEq(token.behaviorFlags() & BehaviorFlags.FEE_ON_TRANSFER, 0);
        assertEq(token.behaviorFlags() & BehaviorFlags.TRANSFER_HOOK, 0);
    }

    function test_ExtensionDataIsEmptyBecauseThereIsNothingToConfigure() public view {
        assertEq(token.extensionData(ExtensionIds.NON_TRANSFERABLE).length, 0);
    }

    /// @dev The restriction module still applies to the flows that remain reachable.
    function test_FreezingStillBlocksMinting() public {
        token.setFrozen(bob, true);
        vm.expectRevert();
        token.mint(bob, 1e18);
    }
}
