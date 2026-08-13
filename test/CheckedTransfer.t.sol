// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ExtendedToken} from "../src/ExtendedToken.sol";
import {IERC20CheckedTransfer} from "../src/interfaces/IERC20CheckedTransfer.sol";
import {BaseTest} from "./BaseTest.sol";

/**
 * @title CheckedTransferTest
 * @notice Pins the guarantee a checked transfer makes: either at least `minAmountReceived` arrives, or
 *         nothing moves at all.
 *
 * @dev The fuzz tests carry the weight. A caller passing `minAmountReceived` is choosing not to snapshot
 *      balances themselves, and that choice is only safe if the floor holds for every amount and every fee
 *      configuration, not just the ones with a unit test.
 *
 *      The epoch tests matter for a different reason. An epoch that advanced on changes it did not need to
 *      would make callers stop passing one, so which setters advance it is as much a part of the contract
 *      as the check itself — hence a test for the metadata setter *not* advancing it.
 */
contract CheckedTransferTest is BaseTest {
    // -----------------------------------------------------------------------------------------------
    // The floor holds
    // -----------------------------------------------------------------------------------------------

    /// @dev Either the transfer delivered at least the floor, or it did not happen. Never in between.
    function testFuzz_EitherTheFloorHoldsOrNothingMoves(
        uint256 amount,
        uint16 basisPoints,
        uint256 cap,
        uint256 minReceived
    ) public {
        amount = bound(amount, 0, INITIAL_BALANCE);
        basisPoints = uint16(bound(basisPoints, 0, token.MAX_FEE_BASIS_POINTS()));
        cap = bound(cap, 0, INITIAL_BALANCE);
        minReceived = bound(minReceived, 0, amount);
        _setFee(basisPoints, cap);

        uint256 recipientBefore = token.balanceOf(carol);
        uint256 senderBefore = token.balanceOf(alice);

        vm.prank(alice);
        try token.transferChecked(carol, amount, minReceived, 0) returns (uint256 received) {
            assertGe(received, minReceived, "a successful checked transfer must clear its floor");
            assertEq(token.balanceOf(carol) - recipientBefore, received, "received must be the real delta");
        } catch {
            assertEq(token.balanceOf(carol), recipientBefore, "a failed checked transfer must move nothing");
            assertEq(token.balanceOf(alice), senderBefore, "a failed checked transfer must cost nothing");
        }
    }

    /// @dev The reported figure is the recipient's measured gain, whatever the extensions did in between.
    function testFuzz_ReceivedEqualsTheRecipientDelta(uint256 amount, uint16 basisPoints) public {
        amount = bound(amount, 0, INITIAL_BALANCE);
        basisPoints = uint16(bound(basisPoints, 0, token.MAX_FEE_BASIS_POINTS()));
        _setFee(basisPoints, type(uint256).max);

        uint256 before = token.balanceOf(carol);

        vm.prank(alice);
        uint256 received = token.transferChecked(carol, amount, 0, 0);

        assertEq(received, token.balanceOf(carol) - before, "received must equal the measured delta");
    }

    function test_TransferCheckedRevertsBelowTheFloor() public {
        _setFee(100, type(uint256).max); // 1%

        uint256 expected = 1000e18 - token.computeFee(alice, carol, 1000e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20CheckedTransfer.ERC20CheckedTransferUnderMinimum.selector, expected, 1000e18)
        );
        token.transferChecked(carol, 1000e18, 1000e18, 0);
    }

    function test_TransferCheckedSucceedsWithNoFee() public {
        vm.prank(alice);
        uint256 received = token.transferChecked(carol, 1000e18, 1000e18, 0);

        assertEq(received, 1000e18, "a fee-free token must deliver the full amount");
        assertEq(token.balanceOf(carol), 1000e18);
    }

    /**
     * @dev The recipient is credited twice — once by the fee leg, once by the main leg — so the whole
     *      amount arrives. Measuring rather than predicting is what gets this right without a special case.
     */
    function test_TransferToTheFeeVaultReportsTheFullAmount() public {
        _setFee(500, type(uint256).max); // 5%

        vm.prank(alice);
        uint256 received = token.transferChecked(vault, 1000e18, 1000e18, 0);

        assertEq(received, 1000e18, "both legs land on the vault, so nothing is lost");
    }

    /// @dev A sender's own balance falls by the fee, so nothing "arrives". Zero is the honest answer.
    function test_SelfTransferReportsZeroReceived() public {
        _setFee(500, type(uint256).max);

        vm.prank(alice);
        uint256 received = token.transferChecked(alice, 1000e18, 0, 0);

        assertEq(received, 0, "a self-transfer delivers nothing it did not already have");
    }

    // -----------------------------------------------------------------------------------------------
    // transferFromChecked
    // -----------------------------------------------------------------------------------------------

    function test_TransferFromCheckedSpendsTheGrossAllowance() public {
        _setFee(100, type(uint256).max);

        vm.prank(alice);
        token.approve(bob, 1000e18);

        vm.prank(bob);
        uint256 received = token.transferFromChecked(alice, carol, 1000e18, 0, 0);

        assertEq(token.allowance(alice, bob), 0, "the allowance covers the amount named, before any fee");
        assertLt(received, 1000e18, "the fee still came out of what arrived");
    }

    function test_TransferFromCheckedRevertsBelowTheFloor() public {
        _setFee(100, type(uint256).max);

        vm.prank(alice);
        token.approve(bob, 1000e18);

        vm.prank(bob);
        vm.expectRevert();
        token.transferFromChecked(alice, carol, 1000e18, 1000e18, 0);

        assertEq(token.allowance(alice, bob), 1000e18, "a reverted transfer must not consume allowance");
    }

    // -----------------------------------------------------------------------------------------------
    // The configuration epoch
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev Starting at 1 is what frees `0` to mean "not checking". Deployed fresh rather than reusing the
     *      fixture, whose `setUp` already sets a fee vault and so has moved the counter on.
     */
    function test_EpochStartsAtOneOnAFreshToken() public {
        ExtendedToken fresh = new ExtendedToken("Fresh", "FRSH", admin);
        assertEq(fresh.configurationEpoch(), 1);
    }

    function test_ZeroEpochSkipsTheCheck() public {
        _setFee(100, type(uint256).max); // advances the epoch

        vm.prank(alice);
        token.transferChecked(carol, 1000e18, 0, 0);
    }

    function test_MatchingEpochPasses() public {
        uint64 epoch = token.configurationEpoch();

        vm.prank(alice);
        token.transferChecked(carol, 1000e18, 0, epoch);
    }

    function test_StaleEpochReverts() public {
        uint64 epoch = token.configurationEpoch();
        _setFee(100, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20CheckedTransfer.ERC20CheckedTransferEpochMismatch.selector, epoch, token.configurationEpoch()
            )
        );
        token.transferChecked(carol, 1000e18, 0, epoch);
    }

    function test_EveryTransferAffectingSetterAdvancesTheEpoch() public {
        uint64 epoch = token.configurationEpoch();

        _setFee(100, type(uint256).max);
        assertEq(token.configurationEpoch(), ++epoch, "fee configuration");

        vm.prank(admin);
        token.setFeeVault(carol);
        assertEq(token.configurationEpoch(), ++epoch, "fee vault");

        vm.prank(admin);
        token.setFeeExempt(bob, true);
        assertEq(token.configurationEpoch(), ++epoch, "fee exemption");

        _setPaused(true);
        assertEq(token.configurationEpoch(), ++epoch, "pause");

        _setFrozen(bob, true);
        assertEq(token.configurationEpoch(), ++epoch, "freeze");

        _setHook(address(0), 0);
        assertEq(token.configurationEpoch(), ++epoch, "hook");
    }

    /**
     * @dev The one that keeps the epoch usable. Metadata is loud but cannot change what a transfer does,
     *      and bricking a pending checked transfer because the token updated its logo would be exactly the
     *      false positive that teaches callers to pass `0` forever.
     */
    function test_MetadataDoesNotAdvanceTheEpoch() public {
        uint64 epoch = token.configurationEpoch();

        vm.startPrank(admin);
        token.setMetadata("website", "https://example.com");
        token.setTokenURI("https://example.com/token.json");
        token.removeMetadata("website");
        vm.stopPrank();

        assertEq(token.configurationEpoch(), epoch, "metadata must not advance the epoch");
    }

    /// @dev Minting and transferring are not configuration; neither should move the counter.
    function test_OrdinaryActivityDoesNotAdvanceTheEpoch() public {
        uint64 epoch = token.configurationEpoch();

        vm.prank(alice);
        token.transfer(carol, 1e18);

        vm.prank(admin);
        token.mint(carol, 1e18);

        assertEq(token.configurationEpoch(), epoch);
    }
}
