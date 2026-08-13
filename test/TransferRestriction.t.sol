// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IERC20TransferRestriction} from "../src/interfaces/IERC20TransferRestriction.sol";
import {BaseTest} from "./BaseTest.sol";

/**
 * @title TransferRestrictionTest
 * @notice Walks the whole pause/freeze table, including the two rows that are asymmetric on purpose.
 */
contract TransferRestrictionTest is BaseTest {
    // -----------------------------------------------------------------------------------------------
    // Transfers
    // -----------------------------------------------------------------------------------------------

    function test_PauseBlocksTransfers() public {
        _setPaused(true);

        assertEq(token.detectTransferRestriction(alice, bob, 1e18), token.RESTRICTION_PAUSED());
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferRestriction.ERC20TransferRestricted.selector, token.RESTRICTION_PAUSED()
            )
        );
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_FrozenSenderCannotTransfer() public {
        _setFrozen(alice, true);

        assertEq(token.detectTransferRestriction(alice, bob, 1e18), token.RESTRICTION_SENDER_FROZEN());
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

        assertEq(token.detectTransferRestriction(alice, bob, 1e18), token.RESTRICTION_RECIPIENT_FROZEN());
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferRestriction.ERC20TransferRestricted.selector, token.RESTRICTION_RECIPIENT_FROZEN()
            )
        );
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_UnfreezingRestoresTransfers() public {
        _setFrozen(alice, true);
        _setFrozen(alice, false);

        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE + 1e18);
    }

    // -----------------------------------------------------------------------------------------------
    // The asymmetric rows
    // -----------------------------------------------------------------------------------------------

    /// @dev A pause must not brick supply management; the authority still needs to be able to act.
    function test_PauseLeavesMintAndBurnAvailable() public {
        _setPaused(true);

        vm.startPrank(admin);
        token.mint(carol, 1000e18);
        assertEq(token.balanceOf(carol), 1000e18);

        token.burn(carol, 400e18);
        assertEq(token.balanceOf(carol), 600e18);
        vm.stopPrank();
    }

    /// @dev Seizure: freezing is what an issuer does *before* settling a balance, so burn must still work.
    function test_BurnWorksOnAFrozenAccount() public {
        _setFrozen(alice, true);

        assertEq(token.detectTransferRestriction(alice, address(0), 1e18), token.RESTRICTION_OK());

        vm.prank(admin);
        token.burn(alice, 1000e18);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 1000e18);
    }

    /// @dev The other direction is not symmetric: crediting an account nobody may transact with is a
    ///      mistake with no upside, so it is rejected.
    function test_MintToAFrozenAccountIsRejected() public {
        _setFrozen(carol, true);

        assertEq(token.detectTransferRestriction(address(0), carol, 1e18), token.RESTRICTION_RECIPIENT_FROZEN());
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferRestriction.ERC20TransferRestricted.selector, token.RESTRICTION_RECIPIENT_FROZEN()
            )
        );
        vm.prank(admin);
        token.mint(carol, 1e18);
    }

    // -----------------------------------------------------------------------------------------------
    // ERC-1404 surface
    // -----------------------------------------------------------------------------------------------

    function test_DetectReturnsZeroWhenNothingIsRestricted() public view {
        assertEq(token.detectTransferRestriction(alice, bob, 1e18), 0);
    }

    function test_DirectGettersTrackTheSameState() public {
        assertFalse(token.transfersPaused());
        assertFalse(token.isFrozen(alice));

        _setPaused(true);
        _setFrozen(alice, true);

        assertTrue(token.transfersPaused());
        assertTrue(token.isFrozen(alice));
        assertFalse(token.isFrozen(bob));
    }

    function test_EveryCodeHasAMessage() public view {
        assertEq(token.messageForTransferRestriction(token.RESTRICTION_OK()), "Transfer allowed");
        assertEq(token.messageForTransferRestriction(token.RESTRICTION_PAUSED()), "Transfers are paused");
        assertEq(token.messageForTransferRestriction(token.RESTRICTION_SENDER_FROZEN()), "Sender account is frozen");
        assertEq(
            token.messageForTransferRestriction(token.RESTRICTION_RECIPIENT_FROZEN()), "Recipient account is frozen"
        );
        assertEq(token.messageForTransferRestriction(200), "Unknown restriction code");
    }

    /// @dev Pause takes precedence over freeze, so the code a caller gets back is stable and explainable.
    function test_PausePrecedesFreezeInTheReportedCode() public {
        _setPaused(true);
        _setFrozen(alice, true);
        assertEq(token.detectTransferRestriction(alice, bob, 1e18), token.RESTRICTION_PAUSED());
    }

    // -----------------------------------------------------------------------------------------------
    // Authority
    // -----------------------------------------------------------------------------------------------

    function test_Events() public {
        vm.expectEmit(false, false, false, true, address(token));
        emit IERC20TransferRestriction.TransferPauseUpdated(true);
        _setPaused(true);

        vm.expectEmit(true, false, false, true, address(token));
        emit IERC20TransferRestriction.AccountFrozen(alice, true);
        _setFrozen(alice, true);
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

    /// @dev The whole point of one role per extension: the fee authority cannot freeze anyone.
    function test_FeeAuthorityCannotFreeze() public {
        address feeOperator = makeAddr("feeOperator");
        bytes32 feeRole = token.FEE_CONFIG_ROLE();

        vm.prank(admin);
        token.grantRole(feeRole, feeOperator);

        vm.prank(feeOperator);
        token.setFeeConfig(100, 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, feeOperator, token.RESTRICTION_ROLE()
            )
        );
        vm.prank(feeOperator);
        token.setFrozen(alice, true);
    }
}
