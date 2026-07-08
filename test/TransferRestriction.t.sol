// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IERC20TransferRestriction} from "../src/interfaces/IERC20TransferRestriction.sol";

import {BaseTest} from "./BaseTest.sol";

contract TransferRestrictionTest is BaseTest {
    function test_PauseBlocksTransfers() public {
        _setPaused(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferRestriction.ERC20TransferRestricted.selector, token.RESTRICTION_PAUSED()
            )
        );
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_UnpauseRestoresTransfers() public {
        _setPaused(true);
        _setPaused(false);

        vm.prank(alice);
        token.transfer(bob, 1e18);

        assertEq(token.balanceOf(bob), INITIAL_BALANCE + 1e18);
    }

    function test_FrozenSenderCannotSend() public {
        _setFrozen(alice, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferRestriction.ERC20TransferRestricted.selector, token.RESTRICTION_SENDER_FROZEN()
            )
        );
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_FrozenRecipientCannotReceive() public {
        _setFrozen(bob, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferRestriction.ERC20TransferRestricted.selector, token.RESTRICTION_RECIPIENT_FROZEN()
            )
        );
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_UnfreezingRestoresTheAccount() public {
        _setFrozen(alice, true);
        _setFrozen(alice, false);

        vm.prank(alice);
        token.transfer(bob, 1e18);

        assertFalse(token.isFrozen(alice));
    }

    function test_DetectReportsWhyBeforeTheTransferIsTried() public {
        assertEq(token.detectTransferRestriction(alice, bob, 1e18), token.RESTRICTION_OK());

        _setPaused(true);
        assertEq(token.detectTransferRestriction(alice, bob, 1e18), token.RESTRICTION_PAUSED());
    }

    function test_MessagesAreRenderable() public view {
        assertEq(token.messageForTransferRestriction(token.RESTRICTION_OK()), "Transfer allowed");
        assertEq(token.messageForTransferRestriction(token.RESTRICTION_PAUSED()), "Transfers are paused");
        assertEq(token.messageForTransferRestriction(200), "Unknown restriction code");
    }

    function test_RestrictionDeclaresPauseAndBlocklist() public view {
        uint256 flags = token.behaviorFlags();

        assertTrue(flags & (1 << 3) != 0);
        assertTrue(flags & (1 << 4) != 0);
    }

    function test_RevertWhen_CallerLacksTheRestrictionRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.RESTRICTION_ROLE()
            )
        );
        vm.prank(alice);
        token.setTransfersPaused(true);
    }
}
