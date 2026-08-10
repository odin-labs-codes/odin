// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ExtendedToken} from "../../src/ExtendedToken.sol";
import {BehaviorFlags} from "../../src/libraries/BehaviorFlags.sol";
import {CheckedRouter, ExtensionAwareRouter, MockPair, NaiveRouter} from "../mocks/MockAmm.sol";
import {PlainERC20} from "../mocks/PlainERC20.sol";

/**
 * @title AmmIntegrationTest
 * @notice The reason this project exists, expressed as a test.
 *
 * @dev A fee-on-transfer token and a constant-product pool are not compatible by default. The pool measures
 *      what it actually received and rejects the trade when the quote assumed more — which is correct of
 *      the pool, and is why routers refuse these tokens rather than lose money to them.
 *
 *      What follows is the same pool, the same token, the same fee, and two routers. The first does what
 *      every router did before fee-on-transfer tokens existed, and fails. The second reads
 *      `behaviorFlags()`, discovers `FEE_ON_TRANSFER`, asks how much the fee will be, and succeeds. The
 *      difference between them is one `view` call — but only because the token made that call possible.
 *
 *      Nothing here changes the token's behaviour. The fee is identical in both runs. The only thing that
 *      changed is that the integrator could find out about it in advance.
 */
contract AmmIntegrationTest is Test {
    ExtendedToken internal feeToken;
    PlainERC20 internal quoteToken;
    MockPair internal pair;
    NaiveRouter internal naiveRouter;
    ExtensionAwareRouter internal awareRouter;
    CheckedRouter internal checkedRouter;

    address internal admin = makeAddr("admin");
    address internal vault = makeAddr("feeVault");
    address internal trader = makeAddr("trader");

    uint256 internal constant POOL_FEE_TOKEN = 1_000_000e18;
    uint256 internal constant POOL_QUOTE_TOKEN = 2_000_000e18;
    uint256 internal constant SWAP_IN = 10_000e18;

    function setUp() public {
        feeToken = new ExtendedToken("Fee Token", "FEE", admin);
        quoteToken = new PlainERC20("Quote Token", "QUOTE");
        pair = new MockPair(address(feeToken), address(quoteToken));

        naiveRouter = new NaiveRouter();
        awareRouter = new ExtensionAwareRouter();
        checkedRouter = new CheckedRouter();

        vm.startPrank(admin);
        feeToken.setFeeVault(vault);
        feeToken.mint(address(pair), POOL_FEE_TOKEN);
        feeToken.mint(trader, 100_000e18);
        // 2% on every transfer, uncapped in practice.
        feeToken.setFeeConfig(200, type(uint128).max);
        vm.stopPrank();

        quoteToken.mint(address(pair), POOL_QUOTE_TOKEN);
        pair.sync();

        vm.startPrank(trader);
        feeToken.approve(address(naiveRouter), type(uint256).max);
        feeToken.approve(address(awareRouter), type(uint256).max);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------------------------------
    // The failure
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev The router quotes on `SWAP_IN`, the pool receives `SWAP_IN` minus the fee, and `x*y` lands below
     *      `k`. The pair rejects it. This is not a contrived failure — it is the standard Uniswap V2 path
     *      meeting a standard fee-on-transfer token.
     */
    function test_NaiveRouterFails() public {
        vm.expectRevert(MockPair.InvariantK.selector);
        vm.prank(trader);
        naiveRouter.swapToken0ForToken1(pair, SWAP_IN, 0);
    }

    /// @dev And it fails for the reason claimed: without the fee, the identical call goes through.
    function test_NaiveRouterSucceedsOnceTheFeeIsOff() public {
        vm.prank(admin);
        feeToken.setFeeConfig(0, 0);

        vm.prank(trader);
        uint256 amountOut = naiveRouter.swapToken0ForToken1(pair, SWAP_IN, 0);

        assertGt(amountOut, 0);
        assertEq(quoteToken.balanceOf(trader), amountOut);
    }

    // -----------------------------------------------------------------------------------------------
    // The fix, three ways
    // -----------------------------------------------------------------------------------------------

    /// @dev Detection first: one call tells the router what it is dealing with — or that it cannot tell.
    function test_RouterDetectsTheBehaviourBeforeQuoting() public view {
        (bool known, uint256 flags) = awareRouter.tryReadBehaviorFlags(address(feeToken));
        assertTrue(known, "a BERC token answers");
        assertGt(flags & BehaviorFlags.FEE_ON_TRANSFER, 0, "and says so up front");

        // A token that has never heard of this framework is unknown, which is not the same as declaring
        // nothing — it could charge a fee of its own and this router would never learn about it.
        (bool plainKnown,) = awareRouter.tryReadBehaviorFlags(address(quoteToken));
        assertFalse(plainKnown, "silence must not be read as a declaration");
    }

    /**
     * @dev And the router acts on that distinction rather than only reporting it. Quoting against an
     *      unclassifiable token is exactly how a fee-on-transfer token outside this framework drains a
     *      router that assumed `0`.
     */
    function test_RouterRefusesToQuoteAnUnknownToken() public {
        MockPair plainPair = new MockPair(address(quoteToken), address(feeToken));

        vm.expectRevert(
            abi.encodeWithSelector(ExtensionAwareRouter.TokenBehaviourUnknown.selector, address(quoteToken))
        );
        vm.prank(trader);
        awareRouter.swapToken0ForToken1(plainPair, SWAP_IN, 0);
    }

    function test_AwareRouterSucceedsUsingComputeFee() public {
        uint256 expectedFee = feeToken.computeFee(trader, address(pair), SWAP_IN);
        assertGt(expectedFee, 0);

        uint256 poolBefore = feeToken.balanceOf(address(pair));

        vm.prank(trader);
        uint256 amountOut = awareRouter.swapToken0ForToken1(pair, SWAP_IN, 0);

        assertGt(amountOut, 0);
        assertEq(quoteToken.balanceOf(trader), amountOut);
        // The quote was computed against exactly what arrived.
        assertEq(feeToken.balanceOf(address(pair)) - poolBefore, SWAP_IN - expectedFee);
        assertEq(feeToken.balanceOf(vault), expectedFee);
    }

    /// @dev No per-swap `view` call: pricing against the declared cap is always conservative.
    function test_AwareRouterSucceedsUsingOnlyTheDeclaredCap() public {
        vm.prank(admin);
        feeToken.setFeeConfig(200, 50e18); // a cap low enough to bind on this size

        vm.prank(trader);
        uint256 amountOut = awareRouter.swapToken0ForToken1WorstCase(pair, SWAP_IN, 0);

        assertGt(amountOut, 0);
        assertEq(quoteToken.balanceOf(trader), amountOut);
    }

    /**
     * @dev The property an off-chain quote pipeline actually needs, tested the way it actually fails.
     *
     *      A quote taken in one block and executed in another has to survive whatever the fee authority
     *      does in between — and the authority can raise the *cap* as well as the rate. So the quote is
     *      captured first as a real, non-zero `amountOutMin`, then both knobs are moved, and only then is
     *      the swap submitted. Pricing against `maximumFee()` cannot pass this: the figure it was built on
     *      no longer exists.
     */
    function test_ACeilingQuoteSurvivesTheAuthorityRaisingBothTheRateAndTheCap() public {
        vm.prank(admin);
        feeToken.setFeeConfig(50, 500e18); // 0.5%, cap 500

        // The quote a user is shown, produced against the configuration visible at that moment, then
        // rolled back so the swap below meets the same reserves the quote was computed from.
        uint256 snapshot = vm.snapshotState();
        vm.prank(trader);
        uint256 quotedOut = awareRouter.swapToken0ForToken1AgainstTheImmutableCeiling(pair, SWAP_IN, 0);
        assertGt(quotedOut, 0, "the quote must be a real number, not zero");
        vm.revertToState(snapshot);

        vm.prank(admin);
        feeToken.setFeeConfig(1000, type(uint128).max); // rate to the ceiling, cap effectively removed

        vm.prank(trader);
        uint256 amountOut = awareRouter.swapToken0ForToken1AgainstTheImmutableCeiling(pair, SWAP_IN, quotedOut);

        assertGe(amountOut, quotedOut, "the ceiling-based quote still holds");
    }

    /**
     * @dev And the contrast that makes the point: a quote built on `maximumFee()` is only good for the
     *      configuration it was read from. Here the cap is raised after the quote, and the same swap
     *      submitted with that stale figure as its floor no longer clears it.
     */
    function test_ACapBasedQuoteDoesNotSurviveTheCapBeingRaised() public {
        vm.prank(admin);
        feeToken.setFeeConfig(50, 100e18); // 0.5%, cap 100

        uint256 snapshot = vm.snapshotState();
        vm.prank(trader);
        uint256 quotedOut = awareRouter.swapToken0ForToken1WorstCase(pair, SWAP_IN, 0);
        assertGt(quotedOut, 0);
        vm.revertToState(snapshot);

        vm.prank(admin);
        feeToken.setFeeConfig(1000, type(uint128).max); // the authority moves the cap the quote assumed

        vm.expectRevert(ExtensionAwareRouter.InsufficientOutputAmount.selector);
        vm.prank(trader);
        awareRouter.swapToken0ForToken1WorstCase(pair, SWAP_IN, quotedOut);
    }

    /**
     * @dev The fourth way, and the one that needs no knowledge of this framework at all: state a floor and
     *      quote on what the token reports arrived. No `behaviorFlags()`, no `computeFee`, no branch.
     */
    function test_CheckedRouterSucceedsWithoutKnowingAboutFeesAtAll() public {
        uint256 expectedArrival = SWAP_IN - feeToken.computeFee(trader, address(pair), SWAP_IN);
        uint256 poolBefore = feeToken.balanceOf(address(pair));

        vm.prank(trader);
        feeToken.approve(address(checkedRouter), type(uint256).max);

        vm.prank(trader);
        uint256 amountOut = checkedRouter.swapToken0ForToken1(pair, SWAP_IN, expectedArrival, 0);

        assertGt(amountOut, 0);
        assertEq(quoteToken.balanceOf(trader), amountOut);
        assertEq(feeToken.balanceOf(address(pair)) - poolBefore, expectedArrival);
    }

    /**
     * @dev And the floor is what makes it safe. The authority raises the fee after the user was quoted; the
     *      swap reverts rather than silently handing them a worse rate.
     */
    function test_CheckedRouterRefusesAfterTheFeeIsRaised() public {
        uint256 quotedArrival = SWAP_IN - feeToken.computeFee(trader, address(pair), SWAP_IN);

        vm.prank(admin);
        feeToken.setFeeConfig(500, type(uint128).max); // 2% becomes 5% between quote and execution

        vm.prank(trader);
        feeToken.approve(address(checkedRouter), type(uint256).max);

        vm.prank(trader);
        vm.expectRevert();
        checkedRouter.swapToken0ForToken1(pair, SWAP_IN, quotedArrival, 0);

        assertEq(quoteToken.balanceOf(trader), 0, "nothing moved");
    }

    /// @dev Exact-in: the pool receives a number the router chose, not one the fee arithmetic left behind.
    function test_AwareRouterSucceedsUsingExactOutTransfer() public {
        uint256 exactPoolIn = 9_000e18;
        uint256 poolBefore = feeToken.balanceOf(address(pair));
        uint256 traderBefore = feeToken.balanceOf(trader);

        vm.prank(trader);
        (uint256 amountOut, uint256 amountPaid) = awareRouter.swapToken0ForToken1ExactIn(pair, exactPoolIn, 0);

        assertGt(amountOut, 0);
        assertEq(feeToken.balanceOf(address(pair)) - poolBefore, exactPoolIn, "pool got the round number");
        assertEq(traderBefore - feeToken.balanceOf(trader), amountPaid);
        assertGt(amountPaid, exactPoolIn, "and the trader covered the fee on top");
    }

    // -----------------------------------------------------------------------------------------------
    // The other way out
    // -----------------------------------------------------------------------------------------------

    /// @dev Exempting the pool is the other supported answer, and it lets the naive router work unchanged.
    ///      The declaration still stands, because the authority can revoke the exemption at any time.
    function test_ExemptingThePoolLetsEvenTheNaiveRouterWork() public {
        vm.prank(admin);
        feeToken.setFeeExempt(address(pair), true);

        assertEq(feeToken.computeFee(trader, address(pair), SWAP_IN), 0);

        vm.prank(trader);
        uint256 amountOut = naiveRouter.swapToken0ForToken1(pair, SWAP_IN, 0);
        assertGt(amountOut, 0);

        assertGt(
            feeToken.behaviorFlags() & BehaviorFlags.FEE_ON_TRANSFER,
            0,
            "still declared: an exemption is configuration, not a change of nature"
        );
    }

    // -----------------------------------------------------------------------------------------------
    // Slippage
    // -----------------------------------------------------------------------------------------------

    function test_AwareRouterStillHonoursSlippageBounds() public {
        vm.prank(trader);
        uint256 fair = awareRouter.swapToken0ForToken1(pair, SWAP_IN, 0);

        vm.expectRevert(ExtensionAwareRouter.InsufficientOutputAmount.selector);
        vm.prank(trader);
        awareRouter.swapToken0ForToken1(pair, SWAP_IN, fair * 2);
    }
}
