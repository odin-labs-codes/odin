// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ExtendedToken} from "../../src/ExtendedToken.sol";
import {RecordingHook} from "../mocks/HookReceivers.sol";

/**
 * @notice Drives the token through arbitrary sequences of transfers, supply changes and reconfigurations,
 *         always between a closed set of accounts so that the balance sum stays checkable.
 */
contract SupplyHandler is Test {
    ExtendedToken public immutable token;
    address public immutable admin;
    address public immutable vault;
    address[] public actors;

    uint256 public transfersMade;
    uint256 public feesCollected;

    constructor(ExtendedToken token_, address admin_, address vault_, address[] memory actors_) {
        token = token_;
        admin = admin_;
        vault = vault_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        try token.transfer(to, amount) {
            transfersMade++;
        } catch {}
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        token.approve(spender, amount);

        vm.prank(spender);
        try token.transferFrom(from, to, amount) {
            transfersMade++;
        } catch {}
    }

    function transferExactOut(uint256 fromSeed, uint256 toSeed, uint256 amountOut) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        // Leave headroom for the fee on top of the requested output.
        amountOut = bound(amountOut, 0, token.balanceOf(from) / 2);

        vm.prank(from);
        try token.transferExactOut(to, amountOut) {
            transfersMade++;
        } catch {}
    }

    function mint(uint256 toSeed, uint256 amount) external {
        amount = bound(amount, 0, 1_000_000e18);
        vm.prank(admin);
        try token.mint(_actor(toSeed), amount) {} catch {}
    }

    function burn(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(admin);
        try token.burn(from, amount) {} catch {}
    }

    function setFeeConfig(uint16 basisPoints, uint256 cap) external {
        basisPoints = uint16(bound(basisPoints, 0, token.MAX_FEE_BASIS_POINTS()));
        cap = bound(cap, 0, 1_000_000e18);
        vm.prank(admin);
        try token.setFeeConfig(basisPoints, cap) {} catch {}
    }

    function setFeeExempt(uint256 seed, bool exempt) external {
        vm.prank(admin);
        token.setFeeExempt(_actor(seed), exempt);
    }

    function setFrozen(uint256 seed, bool frozen) external {
        vm.prank(admin);
        token.setFrozen(_actor(seed), frozen);
    }

    function setPaused(bool paused) external {
        vm.prank(admin);
        token.setTransfersPaused(paused);
    }
}

/**
 * @title SupplyInvariantTest
 * @notice Value is conserved, and declarations are permanent.
 *
 * @dev The first invariant is the one a fee extension most plausibly breaks: a fee that is withheld but
 *      never credited anywhere shrinks the circulating supply without shrinking `totalSupply()`, and the
 *      drift is invisible until someone tries to withdraw the last of it. Summing every account that can
 *      hold a balance — the actors, the vault, and the admin — and comparing to `totalSupply()` catches it
 *      no matter which path leaked.
 *
 *      The second is the promise this whole framework rests on. If `extensions()` or `behaviorFlags()`
 *      could move under any sequence of calls, caching them would be unsafe, and an integrator who cannot
 *      cache them gains nothing over probing the token by hand.
 */
contract SupplyInvariantTest is Test {
    ExtendedToken internal token;
    SupplyHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal vault = makeAddr("feeVault");

    uint256 internal initialFlags;

    function setUp() public {
        token = new ExtendedToken("Invariant Token", "INV", admin);

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");
        actors[3] = makeAddr("actor3");

        vm.startPrank(admin);
        token.setFeeVault(vault);
        token.setTransferHook(address(new RecordingHook()), 200_000);
        for (uint256 i = 0; i < actors.length; i++) {
            token.mint(actors[i], 1_000_000e18);
        }
        vm.stopPrank();

        initialFlags = token.behaviorFlags();

        handler = new SupplyHandler(token, admin, vault, actors);
        targetContract(address(handler));
    }

    function invariant_TotalSupplyEqualsTheSumOfEveryBalance() public view {
        uint256 sum = token.balanceOf(vault) + token.balanceOf(admin);
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply(), "value leaked out of the accounting");
    }

    function invariant_DeclarationsAreImmutable() public view {
        assertEq(token.behaviorFlags(), initialFlags);

        bytes4[] memory ids = token.extensions();
        assertEq(ids.length, 4);
    }

    function invariant_FeeNeverExceedsTheDeclaredMaximum() public view {
        uint256 cap = token.maximumFee();
        address a = handler.actors(0);
        address b = handler.actors(1);

        assertLe(token.computeFee(a, b, 1), cap);
        assertLe(token.computeFee(a, b, 1e18), cap);
        assertLe(token.computeFee(a, b, type(uint128).max), cap);
    }

    /// @dev The relative ceiling is a compile-time constant, so it holds regardless of what the authority
    ///      did to the rate and cap during the run.
    function invariant_FeeNeverExceedsTheImmutableRelativeCeiling() public view {
        address a = handler.actors(0);
        address b = handler.actors(1);
        uint256 amount = 1_000_000e18;

        assertLe(token.computeFee(a, b, amount), amount * token.MAX_FEE_BASIS_POINTS() / 10_000);
    }
}
