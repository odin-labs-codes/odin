// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IERC20TransferHook, ITransferHookReceiver} from "../src/interfaces/IERC20TransferHook.sol";
import {ExtensionIds} from "../src/libraries/ExtensionIds.sol";

import {BaseTest} from "./BaseTest.sol";
import {
    EmptyReturnHook,
    GasBurningHook,
    RecordingHook,
    ReentrantHook,
    ReentrantPullHook,
    RejectingHook,
    ReturnDataBombHook,
    RevertBombHook,
    WrongSelectorHook
} from "./mocks/HookReceivers.sol";

contract TransferHookTest is BaseTest {
    RecordingHook internal recorder;

    function setUp() public override {
        super.setUp();
        recorder = new RecordingHook();
    }

    function test_HookIsCalledWithTheSettledTransfer() public {
        _setHook(address(recorder), 500_000);

        vm.prank(alice);
        token.transfer(bob, 10e18);

        assertEq(recorder.callCount(), 1);
        assertEq(recorder.lastToken(), address(token));
        assertEq(recorder.lastFrom(), alice);
        assertEq(recorder.lastTo(), bob);
        assertEq(recorder.lastValue(), 10e18);
        // Balances have already settled when the hook runs.
        assertEq(recorder.recipientBalanceAtCall(), INITIAL_BALANCE + 10e18);
    }

    function test_HookSeesTheNetValueWhenAFeeApplies() public {
        _setFee(100, type(uint256).max);
        _setHook(address(recorder), 500_000);

        vm.prank(alice);
        token.transfer(bob, 100e18);

        assertEq(recorder.lastValue(), 99e18);
    }

    function test_HookDoesNotFireOnMintOrBurn() public {
        _setHook(address(recorder), 500_000);

        vm.startPrank(admin);
        token.mint(carol, 1e18);
        token.burn(carol, 1e18);
        vm.stopPrank();

        assertEq(recorder.callCount(), 0);
    }

    function test_NoHookInstalledMeansNoCall() public {
        vm.prank(alice);
        token.transfer(bob, 1e18);

        assertEq(token.transferHook(), address(0));
        assertEq(token.transferHookGasLimit(), 0);
    }

    function test_RevertWhen_HookRejects() public {
        RejectingHook rejecting = new RejectingHook();
        _setHook(address(rejecting), 100_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferHook.ERC20TransferHookFailed.selector, abi.encodeWithSelector(RejectingHook.HookSaysNo.selector)
            )
        );
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_RejectionRollsBackTheFeeLegToo() public {
        _setFee(100, type(uint256).max);
        RejectingHook rejecting = new RejectingHook();
        _setHook(address(rejecting), 100_000);

        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 100e18);

        assertEq(token.balanceOf(vault), 0);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE);
    }

    function test_RevertWhen_HookReturnsTheWrongSelector() public {
        WrongSelectorHook wrong = new WrongSelectorHook();
        _setHook(address(wrong), 100_000);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20TransferHook.ERC20TransferHookNotAcknowledged.selector, address(wrong))
        );
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_RevertWhen_HookReturnsNothing() public {
        EmptyReturnHook empty = new EmptyReturnHook();
        _setHook(address(empty), 100_000);

        vm.expectRevert();
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_RevertWhen_HookExceedsItsGasBudget() public {
        GasBurningHook burner = new GasBurningHook();
        _setHook(address(burner), token.MIN_HOOK_GAS_LIMIT());

        vm.expectRevert();
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_AHookCannotChargeTheCallerForItsReturnData() public {
        ReturnDataBombHook bomb = new ReturnDataBombHook();
        _setHook(address(bomb), token.MAX_HOOK_GAS_LIMIT());

        // Several hundred kilobytes come back and none of it is copied here, so the transfer fails on the
        // acknowledgement check rather than by running the caller out of gas.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20TransferHook.ERC20TransferHookNotAcknowledged.selector, address(bomb))
        );
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_AHookCannotChargeTheCallerForItsRevertReason() public {
        RevertBombHook bomb = new RevertBombHook();
        _setHook(address(bomb), token.MAX_HOOK_GAS_LIMIT());

        // 100,000 bytes of revert data, truncated to the 256 the error declares.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20TransferHook.ERC20TransferHookFailed.selector, new bytes(256))
        );
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_AShortRevertReasonSurvivesIntact() public {
        RejectingHook rejecting = new RejectingHook();
        _setHook(address(rejecting), 100_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferHook.ERC20TransferHookFailed.selector,
                abi.encodeWithSelector(RejectingHook.HookSaysNo.selector)
            )
        );
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_ReentrancyIsRejectedAndSurfacesAsAHookFailure() public {
        ReentrantHook reentrant = new ReentrantHook();
        _setHook(address(reentrant), 200_000);

        vm.expectRevert();
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_ReentrancyIsRejectedViaTransferFromToo() public {
        ReentrantPullHook reentrant = new ReentrantPullHook();
        _setHook(address(reentrant), 200_000);

        vm.prank(alice);
        token.approve(address(reentrant), type(uint256).max);

        vm.expectRevert();
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_FeeSplitDoesNotTripTheGuard() public {
        _setFee(100, type(uint256).max);
        _setHook(address(recorder), 500_000);

        vm.prank(alice);
        token.transfer(bob, 100e18);

        assertEq(token.balanceOf(vault), 1e18);
        assertEq(recorder.callCount(), 1);
    }

    function test_RevertWhen_HookIsAnEoa() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20TransferHook.ERC20InvalidTransferHook.selector, alice));
        _setHook(alice, 100_000);
    }

    function test_RevertWhen_GasLimitIsOutOfRange() public {
        uint32 min = token.MIN_HOOK_GAS_LIMIT();
        uint32 max = token.MAX_HOOK_GAS_LIMIT();

        vm.expectRevert(
            abi.encodeWithSelector(IERC20TransferHook.ERC20InvalidHookGasLimit.selector, min - 1, min, max)
        );
        _setHook(address(recorder), min - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20TransferHook.ERC20InvalidHookGasLimit.selector, max + 1, min, max)
        );
        _setHook(address(recorder), max + 1);
    }

    function test_RemovingTheHookAlsoClearsTheAdvertisedBudget() public {
        _setHook(address(recorder), 500_000);
        _setHook(address(0), 100_000);

        assertEq(token.transferHook(), address(0));
        assertEq(token.transferHookGasLimit(), 0);
    }

    function test_ExtensionDataReportsTargetAndBudget() public {
        _setHook(address(recorder), 123_456);

        (address hook, uint32 gasLimit) =
            abi.decode(token.extensionData(ExtensionIds.TRANSFER_HOOK), (address, uint32));

        assertEq(hook, address(recorder));
        assertEq(gasLimit, 123_456);
    }

    function test_Event() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit IERC20TransferHook.TransferHookUpdated(address(recorder), 500_000);

        _setHook(address(recorder), 500_000);
    }

    function test_HookDeclaresTransferHook() public view {
        assertTrue(token.behaviorFlags() & (1 << 2) != 0);
    }

    function test_RevertWhen_CallerLacksTheHookRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.HOOK_CONFIG_ROLE()
            )
        );
        vm.prank(alice);
        token.setTransferHook(address(recorder), 500_000);
    }
}
