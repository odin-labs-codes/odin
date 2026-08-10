// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20Behavior} from "../../src/interfaces/IERC20Behavior.sol";
import {IERC20CheckedTransfer} from "../../src/interfaces/IERC20CheckedTransfer.sol";
import {IERC20TransferFee} from "../../src/interfaces/IERC20TransferFee.sol";
import {BehaviorFlags} from "../../src/libraries/BehaviorFlags.sol";

/**
 * @title MockPair
 * @notice A constant-product pool with Uniswap V2's accounting, including the invariant check that makes
 *         fee-on-transfer tokens fail.
 *
 * @dev The important detail is that the pool measures its *actual* balance after the caller's optimistic
 *      transfer and re-checks `x*y >= k` against it. That is not a quirk of this mock — it is how V2 pairs
 *      work, and it is the exact mechanism by which a token that quietly delivers less than it was asked to
 *      breaks a router that assumed otherwise.
 */
contract MockPair {
    /// @notice `x*y` fell below `k`: the pool received less than the quote assumed.
    error InvariantK();
    error InsufficientLiquidity();
    error InsufficientInputAmount();
    error InsufficientOutputAmount();

    address public immutable token0;
    address public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }

    /// @notice Adopts the current balances as reserves. Stands in for `mint` in a real pair.
    function sync() external {
        reserve0 = IERC20(token0).balanceOf(address(this));
        reserve1 = IERC20(token1).balanceOf(address(this));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to) external {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();

        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        if (amount0Out >= r0 || amount1Out >= r1) revert InsufficientLiquidity();

        if (amount0Out > 0) require(IERC20(token0).transfer(to, amount0Out), "transfer failed");
        if (amount1Out > 0) require(IERC20(token1).transfer(to, amount1Out), "transfer failed");

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        uint256 amount0In = balance0 > r0 - amount0Out ? balance0 - (r0 - amount0Out) : 0;
        uint256 amount1In = balance1 > r1 - amount1Out ? balance1 - (r1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        // 0.30% pool fee, folded into the invariant the way V2 does it.
        uint256 balance0Adjusted = balance0 * 1000 - amount0In * 3;
        uint256 balance1Adjusted = balance1 * 1000 - amount1In * 3;
        if (balance0Adjusted * balance1Adjusted < r0 * r1 * 1_000_000) revert InvariantK();

        reserve0 = balance0;
        reserve1 = balance1;
    }
}

/// @dev Shared constant-product quoting.
abstract contract RouterMath {
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }
}

/**
 * @title NaiveRouter
 * @notice A router written by someone who has never heard of this framework.
 *
 * @dev It does the only reasonable thing given ERC-20's contract: it assumes that moving `amountIn` into
 *      the pool increases the pool's balance by `amountIn`, and quotes accordingly. Nothing here is a
 *      mistake in the ordinary sense — this is what essentially every router did before fee-on-transfer
 *      tokens existed, and what many still do on their default path.
 */
contract NaiveRouter is RouterMath {
    error InsufficientOutputAmount();

    function swapToken0ForToken1(MockPair pair, uint256 amountIn, uint256 amountOutMin)
        external
        returns (uint256 amountOut)
    {
        (uint256 reserveIn, uint256 reserveOut) = pair.getReserves();

        // The whole bug, in one line: `amountIn` is what leaves the user, not what reaches the pool.
        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        if (amountOut < amountOutMin) revert InsufficientOutputAmount();

        IERC20(pair.token0()).transferFrom(msg.sender, address(pair), amountIn);
        pair.swap(0, amountOut, msg.sender);
    }
}

/**
 * @title ExtensionAwareRouter
 * @notice The same router, after reading `behaviorFlags()` once.
 *
 * @dev Four ways of handling the same token, each useful in a different place:
 *
 *      - {swapToken0ForToken1} asks {IERC20TransferFee-computeFee} what the transfer will cost and quotes
 *        on what will actually arrive. Exact, one extra `view` call, no balance snapshots.
 *      - {swapToken0ForToken1WorstCase} prices against {IERC20TransferFee-maximumFee}, read in the same
 *        transaction. Conservative against the *current* configuration — and only that one, since the
 *        authority can raise the cap as easily as the rate.
 *      - {swapToken0ForToken1AgainstTheImmutableCeiling} prices against
 *        {IERC20TransferFee-MAX_FEE_BASIS_POINTS}, which is a compile-time constant. The only one of these
 *        whose quote survives an arbitrary configuration change, and correspondingly the most conservative.
 *      - {swapToken0ForToken1ExactIn} uses {IERC20TransferFee-transferFromExactOut} to make the pool
 *        receive a round number, so the amount the router quotes on is the amount it chose rather than
 *        whatever the fee arithmetic left behind.
 *
 *      All four start from the same detection step, and that step distinguishes three answers rather than
 *      two. A token that does not respond is *unknown*, not plain: an arbitrary fee-on-transfer ERC-20
 *      that never heard of this framework does not answer, and neither does an uninitialised BERC clone
 *      that someone could initialise with a fee tomorrow. Collapsing either into `0` is the mistake
 *      `docs/INTEGRATION.md` opens by warning about, so this router refuses to quote on a token it cannot
 *      classify and leaves that decision to a policy layer above it.
 */
contract ExtensionAwareRouter is RouterMath {
    error InsufficientOutputAmount();

    /// @notice The token did not answer `behaviorFlags()`, so nothing is known about how it behaves.
    error TokenBehaviourUnknown(address token);

    /**
     * @notice Reads a token's declaration.
     * @return known False when the call reverted. Distinct from `flags == 0`, which is a token actively
     *         declaring that it behaves like a plain ERC-20.
     */
    function tryReadBehaviorFlags(address token) public view returns (bool known, uint256 flags) {
        try IERC20Behavior(token).behaviorFlags() returns (uint256 declared) {
            return (true, declared);
        } catch {
            return (false, 0);
        }
    }

    function _declaredFlags(address token) private view returns (uint256) {
        (bool known, uint256 flags) = tryReadBehaviorFlags(token);
        if (!known) revert TokenBehaviourUnknown(token);
        return flags;
    }

    function swapToken0ForToken1(MockPair pair, uint256 amountIn, uint256 amountOutMin)
        external
        returns (uint256 amountOut)
    {
        address tokenIn = pair.token0();
        uint256 effectiveIn = amountIn;

        if (_declaredFlags(tokenIn) & BehaviorFlags.FEE_ON_TRANSFER != 0) {
            // Exactly what the pool will end up holding, known before anything moves.
            effectiveIn = amountIn - IERC20TransferFee(tokenIn).computeFee(msg.sender, address(pair), amountIn);
        }

        (uint256 reserveIn, uint256 reserveOut) = pair.getReserves();
        amountOut = getAmountOut(effectiveIn, reserveIn, reserveOut);
        if (amountOut < amountOutMin) revert InsufficientOutputAmount();

        IERC20(tokenIn).transferFrom(msg.sender, address(pair), amountIn);
        pair.swap(0, amountOut, msg.sender);
    }

    function swapToken0ForToken1WorstCase(MockPair pair, uint256 amountIn, uint256 amountOutMin)
        external
        returns (uint256 amountOut)
    {
        address tokenIn = pair.token0();
        uint256 effectiveIn = amountIn;

        if (_declaredFlags(tokenIn) & BehaviorFlags.FEE_ON_TRANSFER != 0) {
            // Read in the same transaction as the swap, so it reflects the configuration that will execute.
            // A `maximumFee()` cached in an earlier block would *not*: the authority can raise the cap as
            // well as the rate, so a stale value is not an upper bound on anything. For a quote that must
            // outlive a configuration change, see {swapToken0ForToken1AgainstTheImmutableCeiling}.
            // always conservative and never reverts for being too optimistic.
            uint256 worstFee = IERC20TransferFee(tokenIn).maximumFee();
            effectiveIn = amountIn > worstFee ? amountIn - worstFee : 0;
        }

        (uint256 reserveIn, uint256 reserveOut) = pair.getReserves();
        amountOut = getAmountOut(effectiveIn, reserveIn, reserveOut);
        if (amountOut < amountOutMin) revert InsufficientOutputAmount();

        IERC20(tokenIn).transferFrom(msg.sender, address(pair), amountIn);
        pair.swap(0, amountOut, msg.sender);
    }

    /**
     * @notice Prices against the one fee figure no authority can move.
     * @dev `MAX_FEE_BASIS_POINTS` is a compile-time constant, so a quote derived from it survives any
     *      future configuration — including the authority raising the cap, which is exactly what a quote
     *      built on `maximumFee()` does not survive. The price of that durability is a much more
     *      conservative number, which is the trade an off-chain quote pipeline should be making.
     */
    function swapToken0ForToken1AgainstTheImmutableCeiling(MockPair pair, uint256 amountIn, uint256 amountOutMin)
        external
        returns (uint256 amountOut)
    {
        address tokenIn = pair.token0();
        uint256 effectiveIn = amountIn;

        if (_declaredFlags(tokenIn) & BehaviorFlags.FEE_ON_TRANSFER != 0) {
            // `mulDiv` rather than `amountIn * ceiling / 10_000`, which overflows for any `amountIn` above
            // about a tenth of `type(uint256).max`.
            uint256 ceiling = IERC20TransferFee(tokenIn).MAX_FEE_BASIS_POINTS();
            uint256 worstFee = Math.mulDiv(amountIn, ceiling, 10_000);
            effectiveIn = amountIn - worstFee;
        }

        (uint256 reserveIn, uint256 reserveOut) = pair.getReserves();
        amountOut = getAmountOut(effectiveIn, reserveIn, reserveOut);
        if (amountOut < amountOutMin) revert InsufficientOutputAmount();

        IERC20(tokenIn).transferFrom(msg.sender, address(pair), amountIn);
        pair.swap(0, amountOut, msg.sender);
    }

    /// @notice Delivers exactly `exactPoolIn` into the pool, whatever that costs the user.
    function swapToken0ForToken1ExactIn(MockPair pair, uint256 exactPoolIn, uint256 amountOutMin)
        external
        returns (uint256 amountOut, uint256 amountPaid)
    {
        address tokenIn = pair.token0();

        (uint256 reserveIn, uint256 reserveOut) = pair.getReserves();
        amountOut = getAmountOut(exactPoolIn, reserveIn, reserveOut);
        if (amountOut < amountOutMin) revert InsufficientOutputAmount();

        if (_declaredFlags(tokenIn) & BehaviorFlags.FEE_ON_TRANSFER != 0) {
            amountPaid = IERC20TransferFee(tokenIn).transferFromExactOut(msg.sender, address(pair), exactPoolIn);
        } else {
            IERC20(tokenIn).transferFrom(msg.sender, address(pair), exactPoolIn);
            amountPaid = exactPoolIn;
        }

        pair.swap(0, amountOut, msg.sender);
    }
}

/**
 * @title CheckedRouter
 * @notice The same swap again, by a router that knows nothing about fees and is still correct.
 *
 * @dev No `behaviorFlags()`, no `computeFee`, no `maximumFee`, no branch on whether this token charges
 *      anything. It moves the tokens with {IERC20CheckedTransfer-transferFromChecked}, quotes on the amount
 *      the call reports actually arrived, and states a floor so the user cannot be silently repriced by a
 *      fee change landing between simulation and inclusion.
 *
 *      This is the cheapest correct integration available, and it is correct for extension combinations
 *      nobody enumerated — the number it quotes on is measured, not predicted. What the detection layer
 *      buys over this is a quote *before* committing, which a router comparing paths still needs.
 */
contract CheckedRouter is RouterMath {
    error InsufficientOutputAmount();

    /// @param minPoolIn The least the pool may receive. Set it from the quote the user was shown.
    function swapToken0ForToken1(MockPair pair, uint256 amountIn, uint256 minPoolIn, uint256 amountOutMin)
        external
        returns (uint256 amountOut)
    {
        (uint256 reserveIn, uint256 reserveOut) = pair.getReserves();

        uint256 arrived = IERC20CheckedTransfer(pair.token0())
            .transferFromChecked(msg.sender, address(pair), amountIn, minPoolIn, 0);

        amountOut = getAmountOut(arrived, reserveIn, reserveOut);
        if (amountOut < amountOutMin) revert InsufficientOutputAmount();

        pair.swap(0, amountOut, msg.sender);
    }
}
