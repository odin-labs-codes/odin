// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ExtendedToken} from "../src/ExtendedToken.sol";
import {IERC20Extensions} from "../src/interfaces/IERC20Extensions.sol";
import {IERC20TransferFee} from "../src/interfaces/IERC20TransferFee.sol";
import {ExtensionIds} from "../src/libraries/ExtensionIds.sol";
import {BaseTest} from "./BaseTest.sol";

/**
 * @title TransferFeeTest
 * @notice Pins the three promises the fee extension makes, and the arithmetic underneath them.
 *
 * @dev The fuzz tests are the point of this file. A unit test proves the fee is right for the amounts
 *      someone thought to write down; the promise being made is that it is right for every amount, and
 *      that is what an integrator is actually relying on when they skip the balance snapshot.
 */
contract TransferFeeTest is BaseTest {
    // -----------------------------------------------------------------------------------------------
    // The three promises, over arbitrary inputs
    // -----------------------------------------------------------------------------------------------

    /// @dev Predictable: what `computeFee` says beforehand is exactly what goes missing in between.
    function testFuzz_ComputeFeeMatchesTheActualTransfer(uint256 amount, uint16 basisPoints, uint256 cap) public {
        amount = bound(amount, 0, INITIAL_BALANCE);
        basisPoints = uint16(bound(basisPoints, 0, token.MAX_FEE_BASIS_POINTS()));
        cap = bound(cap, 0, INITIAL_BALANCE);
        _setFee(basisPoints, cap);

        uint256 quoted = token.computeFee(alice, carol, amount);

        uint256 senderBefore = token.balanceOf(alice);
        uint256 recipientBefore = token.balanceOf(carol);

        vm.prank(alice);
        token.transfer(carol, amount);

        uint256 debited = senderBefore - token.balanceOf(alice);
        uint256 credited = token.balanceOf(carol) - recipientBefore;

        assertEq(debited, amount, "sender must be debited exactly the requested amount");
        assertEq(debited - credited, quoted, "computeFee must equal debited minus credited");
    }

    /// @dev Bounded: no amount can produce a fee above the declared cap.
    function testFuzz_MaximumFeeIsAnUpperBound(uint256 amount, uint16 basisPoints, uint256 cap) public {
        amount = bound(amount, 0, type(uint128).max);
        basisPoints = uint16(bound(basisPoints, 0, token.MAX_FEE_BASIS_POINTS()));
        cap = bound(cap, 0, type(uint128).max);
        _setFee(basisPoints, cap);

        assertLe(token.computeFee(alice, carol, amount), token.maximumFee());
    }

    /// @dev And reached, for any cap the rate can actually produce: `amount >= cap * 10_000 / bps` gets
    ///      there, which is the condition the interface states.
    function testFuzz_MaximumFeeIsReachedByALargeEnoughAmount(uint16 basisPoints, uint256 cap) public {
        basisPoints = uint16(bound(basisPoints, 1, token.MAX_FEE_BASIS_POINTS()));
        cap = bound(cap, 1, type(uint96).max);
        _setFee(basisPoints, cap);

        // The smallest amount whose uncapped fee reaches the cap.
        uint256 saturating = _ceilDiv(cap * 10_000, basisPoints);
        assertEq(token.computeFee(alice, carol, saturating), token.maximumFee());
    }

    /**
     * @dev The honest limit of the previous test, pinned so the interface's wording stays true. A cap the
     *      rate cannot produce is never reached by any amount whatsoever, so `maximumFee()` is an upper
     *      bound rather than an attained maximum. Integrators pricing worst-case slippage are unaffected;
     *      anyone who read "tight" as "some amount reaches this" would have been wrong here.
     */
    function test_MaximumFeeIsNotReachedWhenTheCapOutrunsTheRate() public {
        _setFee(token.MAX_FEE_BASIS_POINTS(), type(uint256).max);

        // The largest fee the rate can produce, over the largest amount that can exist at all.
        uint256 largestPossible = token.computeFee(alice, carol, type(uint256).max);

        assertLt(largestPossible, token.maximumFee(), "the declared cap is out of the rate's reach");
    }

    /// @dev Invertible: the recipient's credit lands on `amountOut` exactly, with no rounding slack.
    function testFuzz_TransferExactOutDeliversExactly(uint256 amountOut, uint16 basisPoints, uint256 cap) public {
        amountOut = bound(amountOut, 0, INITIAL_BALANCE / 2);
        basisPoints = uint16(bound(basisPoints, 0, token.MAX_FEE_BASIS_POINTS()));
        cap = bound(cap, 0, INITIAL_BALANCE / 4);
        _setFee(basisPoints, cap);

        uint256 senderBefore = token.balanceOf(alice);
        uint256 recipientBefore = token.balanceOf(carol);

        vm.prank(alice);
        uint256 amountIn = token.transferExactOut(carol, amountOut);

        assertEq(token.balanceOf(carol) - recipientBefore, amountOut, "recipient must receive exactly");
        assertEq(senderBefore - token.balanceOf(alice), amountIn, "returned amountIn must be the debit");
    }

    /// @dev Invertible *and minimal*: one unit less would fall short, so the sender never overpays.
    function testFuzz_ExactOutInputIsMinimal(uint256 amountOut, uint16 basisPoints, uint256 cap) public {
        amountOut = bound(amountOut, 1, INITIAL_BALANCE / 2);
        basisPoints = uint16(bound(basisPoints, 0, token.MAX_FEE_BASIS_POINTS()));
        cap = bound(cap, 0, INITIAL_BALANCE / 4);
        _setFee(basisPoints, cap);

        uint256 amountIn = token.computeAmountInForExactOut(alice, carol, amountOut);
        assertEq(amountIn - token.computeFee(alice, carol, amountIn), amountOut, "candidate must be exact");

        uint256 oneLess = amountIn - 1;
        assertLt(oneLess - token.computeFee(alice, carol, oneLess), amountOut, "candidate must be minimal");
    }

    function testFuzz_TransferFromExactOutSpendsGrossAllowance(uint256 amountOut, uint16 basisPoints) public {
        amountOut = bound(amountOut, 1, INITIAL_BALANCE / 2);
        basisPoints = uint16(bound(basisPoints, 0, token.MAX_FEE_BASIS_POINTS()));
        _setFee(basisPoints, type(uint128).max);

        vm.prank(alice);
        token.approve(bob, type(uint256).max - 1);
        uint256 allowanceBefore = token.allowance(alice, bob);

        vm.prank(bob);
        uint256 amountIn = token.transferFromExactOut(alice, carol, amountOut);

        assertEq(allowanceBefore - token.allowance(alice, bob), amountIn);
        assertEq(token.balanceOf(carol), amountOut);
    }

    // -----------------------------------------------------------------------------------------------
    // Arithmetic corners
    // -----------------------------------------------------------------------------------------------

    function test_FeeRoundsDownInTheSendersFavour() public {
        _setFee(100, type(uint128).max); // 1%
        // 1% of 99 is 0.99, which floors to 0.
        assertEq(token.computeFee(alice, bob, 99), 0);
        assertEq(token.computeFee(alice, bob, 100), 1);
        assertEq(token.computeFee(alice, bob, 199), 1);
    }

    function test_CapTakesOverFromTheRate() public {
        _setFee(1000, 50); // 10%, capped at 50 units
        assertEq(token.computeFee(alice, bob, 100), 10);
        assertEq(token.computeFee(alice, bob, 500), 50);
        assertEq(token.computeFee(alice, bob, 10_000), 50);
    }

    function test_ExactOutAcrossTheCapBoundary() public {
        _setFee(1000, 10); // 10%, capped at 10
        // Below the cap the rate governs: 111 in, 11 fee... but 11 exceeds the cap, so 110 in, 10 fee.
        assertEq(token.computeAmountInForExactOut(alice, bob, 100), 110);
        assertEq(token.computeFee(alice, bob, 110), 10);
        // Well under the cap, the pure rate inverse applies.
        assertEq(token.computeAmountInForExactOut(alice, bob, 9), 9);
        assertEq(token.computeAmountInForExactOut(alice, bob, 10), 11);
    }

    function test_DirectGettersTrackTheSameConfiguration() public {
        assertEq(token.feeVault(), vault);
        assertEq(token.feeBasisPoints(), 0);

        _setFee(425, 7e18);
        assertEq(token.feeBasisPoints(), 425);
        assertEq(token.maximumFee(), 7e18);
    }

    function test_MaximumFeeIsZeroWhileTheRateIsZero() public {
        _setFee(0, 1_000_000e18);
        assertEq(token.maximumFee(), 0);

        _setFee(1, 1_000_000e18);
        assertEq(token.maximumFee(), 1_000_000e18);
    }

    function test_ZeroAmountTransfersAreFree() public {
        _setFee(1000, type(uint128).max);
        assertEq(token.computeFee(alice, bob, 0), 0);
        assertEq(token.computeAmountInForExactOut(alice, bob, 0), 0);
    }

    // -----------------------------------------------------------------------------------------------
    // Exemptions
    // -----------------------------------------------------------------------------------------------

    function test_EitherSideBeingExemptWaivesTheFee() public {
        _setFee(500, type(uint128).max);

        vm.prank(admin);
        token.setFeeExempt(carol, true);

        assertEq(token.computeFee(alice, carol, 1000e18), 0, "exempt recipient");
        assertEq(token.computeFee(carol, alice, 1000e18), 0, "exempt sender");
        assertGt(token.computeFee(alice, bob, 1000e18), 0, "unrelated pair still charged");
    }

    function test_VaultIsExemptWithoutBeingConfigured() public {
        _setFee(500, type(uint128).max);
        assertTrue(token.isFeeExempt(vault));

        vm.prank(alice);
        token.transfer(vault, 1000e18);
        // The vault received the whole amount: no fee was skimmed on the way in.
        assertEq(token.balanceOf(vault), 1000e18);
    }

    function test_MintAndBurnAreNeverCharged() public {
        _setFee(1000, type(uint128).max);
        assertEq(token.computeFee(address(0), alice, 1000e18), 0);
        assertEq(token.computeFee(alice, address(0), 1000e18), 0);
    }

    /**
     * @dev The vault's exemption is a property of being the vault, not a mapping entry. Recording it
     *      explicitly at deployment — which both reference scripts used to do — looks identical until the
     *      vault is rotated, at which point the old address stays exempt with nothing explaining why.
     */
    function test_RotatingTheVaultMovesTheExemptionWithIt() public {
        _setFee(250, 1000e18);
        assertTrue(token.isFeeExempt(vault), "the configured vault is exempt");

        address replacement = makeAddr("replacementVault");
        vm.prank(admin);
        token.setFeeVault(replacement);

        assertTrue(token.isFeeExempt(replacement), "the new vault is exempt");
        assertFalse(token.isFeeExempt(vault), "and the old one is not left behind exempt");

        // Both accounts' effective treatment changed, so both must carry a timestamp saying so — a
        // rotation never names either of them in a `setFeeExempt` call.
        assertEq(token.accountState(replacement).configuredAt, uint64(block.timestamp));
        assertEq(token.accountState(vault).configuredAt, uint64(block.timestamp));

        // The old vault now pays like anyone else.
        vm.prank(admin);
        token.mint(vault, 1000e18);
        vm.prank(vault);
        token.transfer(carol, 1000e18);
        assertLt(token.balanceOf(carol), 1000e18, "a former vault is charged the fee");
    }

    function test_AccountStateReportsExemption() public {
        vm.prank(admin);
        token.setFeeExempt(carol, true);

        assertTrue(token.accountState(carol).feeExempt);
        assertEq(token.accountState(carol).configuredAt, uint64(block.timestamp));
        assertEq(token.accountState(alice).configuredAt, 0);
    }

    // -----------------------------------------------------------------------------------------------
    // Exact-output, guarded
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev Exact-output floats the *input*, so a fee raised between quote and execution is paid silently
     *      by the sender — `minAmountReceived` cannot catch it, because the received amount is exactly what
     *      was asked for. This is the scenario the ceiling exists for.
     */
    function test_ExactOutCheckedRefusesAfterTheFeeIsRaised() public {
        _setFee(100, type(uint256).max); // 1%
        uint256 quoted = token.computeAmountInForExactOut(alice, carol, 1000e18);

        _setFee(500, type(uint256).max); // the authority raises it to 5%

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferFee.ERC20ExactOutInputTooHigh.selector,
                token.computeAmountInForExactOut(alice, carol, 1000e18),
                quoted
            )
        );
        token.transferExactOutChecked(carol, 1000e18, quoted, 0);

        assertEq(token.balanceOf(carol), 0, "nothing moved");
    }

    function test_ExactOutCheckedAcceptsExactlyTheCeiling() public {
        _setFee(100, type(uint256).max);
        uint256 quoted = token.computeAmountInForExactOut(alice, carol, 1000e18);

        vm.prank(alice);
        uint256 paid = token.transferExactOutChecked(carol, 1000e18, quoted, 0);

        assertEq(paid, quoted);
        assertEq(token.balanceOf(carol), 1000e18, "the output is still exact");
    }

    function test_ExactOutCheckedHonoursTheEpoch() public {
        _setFee(100, type(uint256).max);
        uint64 epoch = token.configurationEpoch();

        vm.prank(alice);
        token.transferExactOutChecked(carol, 100e18, type(uint256).max, epoch);

        _setFee(200, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert();
        token.transferExactOutChecked(carol, 100e18, type(uint256).max, epoch);
    }

    function test_TransferFromExactOutCheckedHonoursTheCeiling() public {
        _setFee(100, type(uint256).max);

        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert();
        token.transferFromExactOutChecked(alice, carol, 1000e18, 1000e18, 0);

        assertEq(token.balanceOf(carol), 0);
    }

    /// @dev The unguarded entry points are the guarded ones with the guards opened all the way.
    function testFuzz_ExactOutNeverCostsMoreThanTheCeiling(uint256 amountOut, uint16 basisPoints, uint256 ceiling)
        public
    {
        amountOut = bound(amountOut, 1, INITIAL_BALANCE / 2);
        basisPoints = uint16(bound(basisPoints, 0, token.MAX_FEE_BASIS_POINTS()));
        ceiling = bound(ceiling, 0, INITIAL_BALANCE);
        _setFee(basisPoints, type(uint256).max);

        uint256 senderBefore = token.balanceOf(alice);

        vm.prank(alice);
        try token.transferExactOutChecked(carol, amountOut, ceiling, 0) returns (uint256 paid) {
            assertLe(paid, ceiling, "a success must respect the ceiling");
            assertEq(senderBefore - token.balanceOf(alice), paid, "and charge exactly what it reported");
        } catch {
            assertEq(token.balanceOf(alice), senderBefore, "a failure must cost nothing");
        }
    }

    // -----------------------------------------------------------------------------------------------
    // Exact-output at the edges of uint256
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev The whole `uint256` range, checked as pure arithmetic so the amounts are not limited by what
     *      anyone could hold. Two properties: a quote that succeeds delivers exactly `amountOut`, and no
     *      smaller input does. A quote that reverts is only allowed when even `type(uint256).max` falls
     *      short — `net` is non-decreasing, so that is precisely "no input reaches this output".
     */
    function testFuzz_ExactOutQuoteIsCorrectAndMinimalAcrossTheWholeRange(
        uint256 amountOut,
        uint16 basisPoints,
        uint256 cap
    ) public {
        amountOut = bound(amountOut, 1, type(uint256).max);
        basisPoints = uint16(bound(basisPoints, 1, token.MAX_FEE_BASIS_POINTS()));
        _setFee(basisPoints, cap);

        try token.computeAmountInForExactOut(alice, carol, amountOut) returns (uint256 amountIn) {
            assertEq(amountIn - token.computeFee(alice, carol, amountIn), amountOut, "the quote must deliver");

            uint256 justBelow = amountIn - 1;
            assertLt(justBelow - token.computeFee(alice, carol, justBelow), amountOut, "and nothing smaller may");
        } catch {
            uint256 largest = type(uint256).max;
            assertLt(
                largest - token.computeFee(alice, carol, largest),
                amountOut,
                "a revert is only honest when no input at all reaches this output"
            );
        }
    }

    /**
     * @dev The case that used to revert. With the cap at zero the fee is always zero, so the answer is
     *      `amountOut` itself and obviously fits — but the uncapped inverse of `type(uint256).max` is about
     *      1.11x that, and computing it first blew up on an input whose real answer was never in doubt.
     */
    function test_ExactOutHandlesTheLargestOutputWhenTheCapIsZero() public {
        _setFee(token.MAX_FEE_BASIS_POINTS(), 0);

        assertEq(token.computeAmountInForExactOut(alice, carol, type(uint256).max), type(uint256).max);
    }

    /**
     * @dev The single input where the limit's rounding decides the answer, pinned deterministically
     *      because fuzzing will not find it: `amountOut - 1` lands exactly on `floor(MAX*k/D)`, one value
     *      out of 2^256. Rounding the limit down excluded it and sent a representable answer — precisely
     *      `type(uint256).max` — down the capped path to overflow.
     */
    function test_ExactOutHandlesTheInputThatLandsOnTheRoundingBoundary() public {
        _setFee(token.MAX_FEE_BASIS_POINTS(), type(uint256).max);

        uint256 k = 10_000 - uint256(token.MAX_FEE_BASIS_POINTS());
        uint256 amountOut = Math.mulDiv(type(uint256).max, k, 10_000) + 1;

        uint256 amountIn = token.computeAmountInForExactOut(alice, carol, amountOut);

        assertEq(amountIn, type(uint256).max, "the answer is representable and must be returned");
        assertEq(amountIn - token.computeFee(alice, carol, amountIn), amountOut, "and it delivers");
        assertLt((amountIn - 1) - token.computeFee(alice, carol, amountIn - 1), amountOut, "and nothing smaller does");
    }

    /// @dev One past what fits is a declared error now, not a bare arithmetic panic.
    function test_ExactOutReportsAnUnrepresentableAnswerAsADeclaredError() public {
        _setFee(token.MAX_FEE_BASIS_POINTS(), 1000);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20TransferFee.ERC20ExactOutUnrepresentable.selector, type(uint256).max)
        );
        token.computeAmountInForExactOut(alice, carol, type(uint256).max);
    }

    /// @dev A small cap binds long before the uncapped inverse would fit, and the answer is exact.
    function test_ExactOutHandlesTheLargestRepresentableAnswer() public {
        _setFee(token.MAX_FEE_BASIS_POINTS(), 1000);

        uint256 amountOut = type(uint256).max - 1000;
        assertEq(token.computeAmountInForExactOut(alice, carol, amountOut), type(uint256).max);
    }

    /**
     * @dev Pins the ordering inside the inverse. Both 49 and 50 deliver 45 here, so a version that checked
     *      the capped candidate `amountOut + cap` first and returned it on sight would answer 50 — correct
     *      output, wrong contract: the caller would overpay by one.
     */
    function test_ExactOutStaysMinimalWhereBothBranchesReachTheOutput() public {
        _setFee(1000, 5); // 10%, cap 5

        assertEq(token.computeAmountInForExactOut(alice, carol, 45), 49);
        assertEq(49 - token.computeFee(alice, carol, 49), 45, "the smaller candidate really does deliver");
        assertEq(50 - token.computeFee(alice, carol, 50), 45, "so does the capped one, which is why order matters");
    }

    /**
     * @dev The quote and the transfer must agree on rejection too, or a caller who simulates first is
     *      told a transfer will work that cannot.
     */
    function test_ExactOutQuoteRejectsZeroAddressesLikeTheTransferWould() public {
        _setFee(100, type(uint256).max);

        vm.expectRevert();
        token.computeAmountInForExactOut(address(0), carol, 100e18);

        vm.expectRevert();
        token.computeAmountInForExactOut(alice, address(0), 100e18);

        // And the transfer itself refuses the same pair.
        vm.prank(alice);
        vm.expectRevert();
        token.transferExactOut(address(0), 100e18);
    }

    /**
     * @dev The recipient's balance cannot rise by `amountOut` when the recipient is also paying the fee,
     *      so there is no honest way to keep the promise. Rejected in the view as well, so a caller
     *      simulating first learns the same thing.
     */
    function test_ExactOutRejectsSelfTransfer() public {
        _setFee(100, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20TransferFee.ERC20ExactOutToSelf.selector, alice));
        token.transferExactOut(alice, 100e18);

        vm.expectRevert(abi.encodeWithSelector(IERC20TransferFee.ERC20ExactOutToSelf.selector, alice));
        token.computeAmountInForExactOut(alice, alice, 100e18);
    }

    /// @dev Rejected even where no fee would apply, so the rule does not depend on configuration.
    function test_ExactOutRejectsSelfTransferWithNoFee() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20TransferFee.ERC20ExactOutToSelf.selector, alice));
        token.transferExactOut(alice, 100e18);
    }

    // -----------------------------------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------------------------------

    function test_RevertWhen_RateExceedsTheImmutableCeiling() public {
        uint16 ceiling = token.MAX_FEE_BASIS_POINTS();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20TransferFee.ERC20FeeBasisPointsTooHigh.selector, ceiling + 1, ceiling)
        );
        _setFee(ceiling + 1, 1e18);
    }

    function test_RevertWhen_RateIsSetWithNoVault() public {
        // A freshly deployed token has no vault yet, which is the state this guard exists for.
        ExtendedToken fresh = new ExtendedToken("Fresh", "FRSH", admin);

        vm.expectRevert(IERC20TransferFee.ERC20FeeVaultNotSet.selector);
        vm.prank(admin);
        fresh.setFeeConfig(100, 1e18);

        // Zero is still permitted without a vault, so a token can be assembled and left fee-free.
        vm.prank(admin);
        fresh.setFeeConfig(0, 0);
        assertEq(fresh.maximumFee(), 0);
    }

    function test_RevertWhen_VaultIsTheZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20TransferFee.ERC20InvalidFeeVault.selector, address(0)));
        vm.prank(admin);
        token.setFeeVault(address(0));
    }

    function test_ConfigurationEmitsBothItsOwnEventAndTheGenericOne() public {
        vm.expectEmit(false, false, false, true, address(token));
        emit IERC20TransferFee.FeeConfigUpdated(250, 99e18);

        vm.expectEmit(true, false, false, true, address(token));
        emit IERC20Extensions.ExtensionConfigured(
            ExtensionIds.TRANSFER_FEE, abi.encode(uint16(250), uint256(99e18), vault)
        );

        _setFee(250, 99e18);
    }

    function test_ExtensionDataDecodesToTheLiveConfiguration() public {
        _setFee(375, 42e18);
        (uint16 basisPoints, uint256 cap, address feeVault) =
            abi.decode(token.extensionData(ExtensionIds.TRANSFER_FEE), (uint16, uint256, address));

        assertEq(basisPoints, 375);
        assertEq(cap, 42e18);
        assertEq(feeVault, vault);
    }

    function test_FeeCollectionEmitsItsOwnEvent() public {
        _setFee(100, type(uint128).max);
        uint256 fee = token.computeFee(alice, bob, 1000e18);

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20TransferFee.TransferFeeCollected(alice, bob, fee);

        vm.prank(alice);
        token.transfer(bob, 1000e18);
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
