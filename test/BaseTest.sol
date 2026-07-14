// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ExtendedToken} from "../src/ExtendedToken.sol";

/// @dev Shared fixture: a fully assembled token, a funded cast of actors, and helpers for the things almost
///      every test needs to change.
abstract contract BaseTest is Test {
    ExtendedToken internal token;

    address internal admin = makeAddr("admin");
    address internal vault = makeAddr("feeVault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant INITIAL_BALANCE = 1_000_000e18;

    function setUp() public virtual {
        token = new ExtendedToken("Extended Token", "EXT", admin);

        vm.startPrank(admin);
        token.setFeeVault(vault);
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        vm.stopPrank();
    }

    function _setFee(uint16 basisPoints) internal {
        vm.prank(admin);
        token.setFeeConfig(basisPoints);
    }

    function _setFrozen(address account, bool frozen) internal {
        vm.prank(admin);
        token.setFrozen(account, frozen);
    }

    function _setPaused(bool paused) internal {
        vm.prank(admin);
        token.setTransfersPaused(paused);
    }
}
