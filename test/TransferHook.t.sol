// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IERC20TransferHook} from "../src/interfaces/IERC20TransferHook.sol";
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

    // -----------------------------------------------------------------------------------------------
    // What the hook sees
    // -----------------------------------------------------------------------------------------------

    function test_HookIsCalledWithTheSettledTransfer() public {
        _setHook(address(recorder), 200_000);

        vm.prank(alice);
        token.transfer(bob, 500e18);

        assertEq(recorder.callCount(), 1);
        assertEq(recorder.lastToken(), address(token));
        assertEq(recorder.lastFrom(), alice);
        assertEq(recorder.lastTo(), bob);
        assertEq(recorder.lastValue(), 500e18);
    }

    /// @dev The value handed to the hook is what the recipient actually got, not what was asked for.
    function test_HookSeesTheNetValueWhenAFeeApplies() public {
        _setHook(address(recorder), 200_000);
        _setFee(1000, type(uint128).max); // 10%

        vm.prank(alice);
        token.transfer(bob, 1000e18);

        assertEq(recorder.lastValue(), 900e18);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE + 900e18);
    }

    function test_HookDoesNotFireOnMintOrBurn() public {
        _setHook(address(recorder), 200_000);

        vm.startPrank(admin);
        token.mint(carol, 100e18);
        token.burn(carol, 50e18);
        vm.stopPrank();

        assertEq(recorder.callCount(), 0);
    }

    function test_NoHookInstalledMeansNoCall() public {
        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(recorder.callCount(), 0);
    }

    // -----------------------------------------------------------------------------------------------
    // A hook can veto
    // -----------------------------------------------------------------------------------------------

    function test_RevertWhen_HookRejects() public {
        RejectingHook rejecting = new RejectingHook();
        _setHook(address(rejecting), 100_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferHook.ERC20TransferHookFailed.selector,
                abi.encodeWithSelector(RejectingHook.HookRejected.selector)
            )
        );
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    /// @dev A veto rolls the whole pipeline back, fee leg included. Phases are not independently committed.
    function test_RejectionRollsBackTheFeeLegToo() public {
        _setFee(500, type(uint128).max);
        RejectingHook rejecting = new RejectingHook();
        _setHook(address(rejecting), 100_000);

        uint256 vaultBefore = token.balanceOf(vault);

        vm.prank(alice);
        try token.transfer(bob, 1000e18) {
            fail();
        } catch {}

        assertEq(token.balanceOf(vault), vaultBefore);
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
        EmptyReturnHook silent = new EmptyReturnHook();
        _setHook(address(silent), 100_000);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20TransferHook.ERC20TransferHookNotAcknowledged.selector, address(silent))
        );
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    /// @dev The gas budget is real: a hook that exceeds it fails inside its own frame and takes the
    ///      transfer with it, rather than draining the caller's whole gas allowance.
    function test_RevertWhen_HookExceedsItsGasBudget() public {
        GasBurningHook burner = new GasBurningHook();
        _setHook(address(burner), token.MIN_HOOK_GAS_LIMIT());

        vm.expectRevert(abi.encodeWithSelector(IERC20TransferHook.ERC20TransferHookFailed.selector, bytes("")));
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    // -----------------------------------------------------------------------------------------------
    // Return data
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev The gas bound only means something if it also bounds what the *caller* pays. A high-level call
     *      copies the callee's return data into memory at the caller's expense, after the hook's stipend
     *      has been released — so a hook that spends its budget expanding memory and hands the result back
     *      charges the token roughly its whole budget a second time.
     *
     *      `transferHookGasLimit() * 64 / 63` is the figure `docs/INTEGRATION.md` tells integrators to set
     *      aside. This asserts that figure survives contact with a hostile hook.
     */
    function test_AHookCannotChargeTheCallerForItsReturnData() public {
        uint32 gasLimit = token.MAX_HOOK_GAS_LIMIT();
        // 500kB is about what a hook can afford to allocate inside a 1,000,000 gas stipend.
        _setHook(address(new ReturnDataBombHook(500_000)), gasLimit);

        vm.prank(alice);
        uint256 before = gasleft();
        (bool ok,) = address(token).call(abi.encodeWithSignature("transfer(address,uint256)", bob, 1e18));
        uint256 spent = before - gasleft();

        assertFalse(ok, "a buffer of zeros is not an acknowledgement");
        // The promise made in `docs/INTEGRATION.md`, asserted literally. Measured: 553,505 with the copy
        // bounded, 1,125,052 without — so this threshold is the difference between the two, not a margin
        // chosen to be comfortable.
        assertLt(spent, (uint256(gasLimit) * 64) / 63, "a hostile hook must not exceed its published budget");
    }

    /// @dev The same bound applies to a revert reason, which is return data by another name.
    function test_AHookCannotChargeTheCallerForItsRevertReason() public {
        uint32 gasLimit = token.MAX_HOOK_GAS_LIMIT();
        _setHook(address(new RevertBombHook(500_000)), gasLimit);

        vm.prank(alice);
        uint256 before = gasleft();
        (bool ok, bytes memory err) =
            address(token).call(abi.encodeWithSignature("transfer(address,uint256)", bob, 1e18));
        uint256 spent = before - gasleft();

        assertFalse(ok);
        assertLt(spent, (uint256(gasLimit) * 64) / 63, "a hostile hook must not exceed its published budget");
        // `ERC20TransferHookFailed(bytes)` carries a prefix, not the whole 500kB the hook produced.
        assertLt(err.length, 512, "the carried reason must be truncated");
    }

    /// @dev Truncating must not break the ordinary case: a short reason still arrives intact.
    function test_AShortRevertReasonSurvivesIntact() public {
        RejectingHook rejecter = new RejectingHook();
        _setHook(address(rejecter), token.MIN_HOOK_GAS_LIMIT());

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferHook.ERC20TransferHookFailed.selector,
                abi.encodeWithSelector(RejectingHook.HookRejected.selector)
            )
        );
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    // -----------------------------------------------------------------------------------------------
    // Reentrancy
    // -----------------------------------------------------------------------------------------------

    /// @dev The attack the guard exists for: a policy contract that calls back into the token from inside
    ///      the hook, while the caller's transfer is still on the stack. The inner call reverts on the
    ///      guard, which fails the hook, which reverts the transfer — so the outer error names both.
    function test_ReentrancyIsRejectedAndSurfacesAsAHookFailure() public {
        ReentrantHook attacker = new ReentrantHook(address(token));
        _setHook(address(attacker), 200_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferHook.ERC20TransferHookFailed.selector,
                abi.encodeWithSelector(ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector)
            )
        );
        vm.prank(alice);
        token.transfer(bob, 100e18);
    }

    /// @dev The guard covers `_update`, not one entry point, so the pull path is closed as well.
    function test_ReentrancyIsRejectedViaTransferFromToo() public {
        ReentrantPullHook attacker = new ReentrantPullHook();
        _setHook(address(attacker), 200_000);

        vm.prank(alice);
        token.approve(address(attacker), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferHook.ERC20TransferHookFailed.selector,
                abi.encodeWithSelector(ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector)
            )
        );
        vm.prank(alice);
        token.transfer(bob, 100e18);
    }

    /// @dev The fee module splits a transfer into two balance movements; that must not trip the guard on
    ///      itself, which is why the fee leg bypasses the virtual `_update`.
    function test_FeeSplitDoesNotTripTheGuard() public {
        _setFee(500, type(uint128).max);
        _setHook(address(recorder), 200_000);

        vm.prank(alice);
        token.transfer(bob, 1000e18);

        assertEq(token.balanceOf(vault), 50e18);
        assertEq(recorder.callCount(), 1);
    }

    // -----------------------------------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------------------------------

    function test_RevertWhen_HookIsAnEoa() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(IERC20TransferHook.ERC20InvalidTransferHook.selector, eoa));
        _setHook(eoa, 100_000);
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
        _setHook(address(recorder), 200_000);
        assertEq(token.transferHookGasLimit(), 200_000);

        _setHook(address(0), 200_000);
        assertEq(token.transferHook(), address(0));
        assertEq(token.transferHookGasLimit(), 0, "no budget is advertised for a hook that will not run");

        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(recorder.callCount(), 0);
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
        emit IERC20TransferHook.TransferHookUpdated(address(recorder), 200_000);
        _setHook(address(recorder), 200_000);
    }

    function test_RevertWhen_CallerLacksTheHookRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.HOOK_CONFIG_ROLE()
            )
        );
        vm.prank(alice);
        token.setTransferHook(address(recorder), 100_000);
    }
}
