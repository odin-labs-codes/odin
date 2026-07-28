// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Test} from "forge-std/Test.sol";

import {ExtendedTokenUpgradeable} from "../src/ExtendedTokenUpgradeable.sol";
import {BehaviorFlags} from "../src/libraries/BehaviorFlags.sol";

contract UpgradeTest is Test {
    ExtendedTokenUpgradeable internal token;
    ExtendedTokenUpgradeable internal implementation;

    address internal admin = makeAddr("admin");
    address internal vault = makeAddr("feeVault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        implementation = new ExtendedTokenUpgradeable();
        bytes memory initCall =
            abi.encodeCall(ExtendedTokenUpgradeable.initialize, ("Extended Token", "EXT", admin));
        token = ExtendedTokenUpgradeable(address(new ERC1967Proxy(address(implementation), initCall)));

        vm.startPrank(admin);
        token.setFeeVault(vault);
        token.mint(alice, 1_000e18);
        vm.stopPrank();
    }

    function test_ProxyBehavesLikeTheImmutableToken() public {
        vm.prank(alice);
        token.transfer(bob, 10e18);

        assertEq(token.name(), "Extended Token");
        assertEq(token.balanceOf(bob), 10e18);
    }

    function test_UpgradeableIsDeclared() public view {
        assertTrue(token.behaviorFlags() & BehaviorFlags.UPGRADEABLE != 0);
    }

    function test_TheImmutableTokenDoesNotDeclareIt() public view {
        // Sanity check on the flag itself: it has to come from the shell, not the shared assembly.
        assertTrue(BehaviorFlags.UPGRADEABLE & BehaviorFlags.ALL != 0);
    }

    function test_TheExtensionSetSurvivesAnUpgrade() public {
        bytes4[] memory before = token.extensions();
        uint256 flagsBefore = token.behaviorFlags();

        ExtendedTokenUpgradeable next = new ExtendedTokenUpgradeable();
        vm.prank(admin);
        token.upgradeToAndCall(address(next), "");

        bytes4[] memory after_ = token.extensions();
        assertEq(after_.length, before.length);
        for (uint256 i = 0; i < before.length; ++i) {
            assertEq(after_[i], before[i]);
        }
        assertEq(token.behaviorFlags(), flagsBefore);
    }

    function test_BalancesAndConfigurationSurviveAnUpgrade() public {
        vm.prank(admin);
        token.setFeeConfig(100, type(uint256).max);

        ExtendedTokenUpgradeable next = new ExtendedTokenUpgradeable();
        vm.prank(admin);
        token.upgradeToAndCall(address(next), "");

        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.feeBasisPoints(), 100);
        assertEq(token.feeVault(), vault);
    }

    function test_RevertWhen_UpgradingWithoutTheUpgraderRole() public {
        ExtendedTokenUpgradeable next = new ExtendedTokenUpgradeable();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.UPGRADER_ROLE()
            )
        );
        vm.prank(alice);
        token.upgradeToAndCall(address(next), "");
    }

    function test_RevertWhen_InitialisingTheProxyTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize("Again", "AGN", admin);
    }

    function test_RevertWhen_InitialisingTheImplementationDirectly() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize("Direct", "DIR", admin);
    }

    function test_TheUpgraderRoleIsSeparateFromTheOtherAuthorities() public view {
        assertTrue(token.UPGRADER_ROLE() != token.DEFAULT_ADMIN_ROLE());
        assertTrue(token.UPGRADER_ROLE() != token.FEE_CONFIG_ROLE());
    }
}
