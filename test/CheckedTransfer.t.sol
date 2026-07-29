// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ExtendedToken} from "../src/ExtendedToken.sol";
import {IERC20CheckedTransfer} from "../src/interfaces/IERC20CheckedTransfer.sol";
import {IERC20TransferFee} from "../src/interfaces/IERC20TransferFee.sol";

import {BaseTest} from "./BaseTest.sol";

contract CheckedTransferTest is BaseTest {
    function test_ReturnsWhatActuallyArrived() public {
        _setFee(100, type(uint256).max);

        vm.prank(alice);
        uint256 received = token.transferChecked(bob, 100e18, 99e18, 0);

        assertEq(received, 99e18);
    }

    function test_AnExactTransferDemandsTheWholeAmount() public {
        vm.prank(alice);
        uint256 received = token.transferChecked(bob, 100e18, 100e18, 0);

        assertEq(received, 100e18);
    }

    function test_RevertWhen_LessArrivesThanTheFloor() public {
        _setFee(100, type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20CheckedTransfer.ERC20CheckedTransferUnderMinimum.selector, 99e18, 100e18)
        );
        vm.prank(alice);
        token.transferChecked(bob, 100e18, 100e18, 0);
    }

    function test_TheFloorIsMeasuredNotPredicted() public {
        _setFee(100, type(uint256).max);

        // The vault is credited by both legs, so the whole amount really does arrive.
        vm.prank(alice);
        uint256 received = token.transferChecked(vault, 100e18, 100e18, 0);

        assertEq(received, 100e18);
    }

    function test_ASelfTransferReportsZeroRatherThanUnderflowing() public {
        _setFee(100, type(uint256).max);

        vm.prank(alice);
        uint256 received = token.transferChecked(alice, 100e18, 0, 0);

        assertEq(received, 0);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 1e18);
    }

    function test_CheckedTransferFromSpendsTheGrossAllowance() public {
        _setFee(100, type(uint256).max);

        vm.prank(alice);
        token.approve(carol, 100e18);

        vm.prank(carol);
        uint256 received = token.transferFromChecked(alice, bob, 100e18, 99e18, 0);

        assertEq(received, 99e18);
        assertEq(token.allowance(alice, carol), 0);
    }

    function test_TheEpochStartsAtOneSoZeroCanMeanUnchecked() public {
        ExtendedToken fresh = new ExtendedToken("Fresh", "FRS", admin);

        assertEq(fresh.configurationEpoch(), 1);
    }

    function test_FeeChangesAdvanceTheEpoch() public {
        uint64 before = token.configurationEpoch();

        _setFee(100, type(uint256).max);

        assertEq(token.configurationEpoch(), before + 1);
    }

    function test_PerAccountChangesAdvanceItToo() public {
        uint64 before = token.configurationEpoch();

        vm.startPrank(admin);
        token.setFeeExempt(carol, true);
        token.setFrozen(carol, true);
        vm.stopPrank();

        assertEq(token.configurationEpoch(), before + 2);
    }

    function test_MetadataChangesDoNotAdvanceIt() public {
        uint64 before = token.configurationEpoch();

        vm.startPrank(admin);
        token.setMetadata("website", "https://example.com");
        token.setTokenURI("ipfs://doc");
        vm.stopPrank();

        // Bricking a treasury's pending checked transfer because the logo URI changed is the failure mode
        // that makes callers stop using the epoch at all.
        assertEq(token.configurationEpoch(), before);
    }

    function test_AMatchingEpochPassesTheCheck() public {
        uint64 epoch = token.configurationEpoch();

        vm.prank(alice);
        token.transferChecked(bob, 1e18, 1e18, epoch);
    }

    function test_RevertWhen_TheEpochMovedUnderTheCaller() public {
        uint64 quoted = token.configurationEpoch();
        _setFee(100, type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20CheckedTransfer.ERC20CheckedTransferEpochMismatch.selector, quoted, quoted + 1
            )
        );
        vm.prank(alice);
        token.transferChecked(bob, 100e18, 0, quoted);
    }

    function test_ZeroSkipsTheEpochCheckEntirely() public {
        _setFee(100, type(uint256).max);

        vm.prank(alice);
        token.transferChecked(bob, 100e18, 99e18, 0);
    }

    function test_ExactOutHasItsOwnCeilingOnWhatTheSenderWillPay() public {
        _setFee(100, type(uint256).max);
        uint256 quoted = token.computeAmountInForExactOut(alice, bob, 99e18);

        vm.prank(alice);
        assertEq(token.transferExactOutChecked(bob, 99e18, quoted, 0), quoted);
    }

    function test_RevertWhen_ExactOutWouldCostMoreThanAllowed() public {
        _setFee(1_000, type(uint256).max);
        uint256 quoted = token.computeAmountInForExactOut(alice, bob, 99e18);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20TransferFee.ERC20ExactOutInputTooHigh.selector, quoted, quoted - 1)
        );
        vm.prank(alice);
        token.transferExactOutChecked(bob, 99e18, quoted - 1, 0);
    }
}
