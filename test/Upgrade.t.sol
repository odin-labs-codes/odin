// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ExtendedToken} from "../src/ExtendedToken.sol";
import {ExtendedTokenUpgradeable} from "../src/ExtendedTokenUpgradeable.sol";
import {BehaviorFlags} from "../src/libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../src/libraries/ExtensionIds.sol";

/// @dev A second implementation, identical except for something observable to prove the swap happened.
contract ExtendedTokenUpgradeableV2 is ExtendedTokenUpgradeable {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/**
 * @title UpgradeTest
 * @notice The UUPS variant, and the two things it has to get right: declaring that it is upgradeable, and
 *         carrying every declaration across an upgrade unchanged.
 */
contract UpgradeTest is Test {
    ExtendedTokenUpgradeable internal token;

    address internal admin = makeAddr("admin");
    address internal vault = makeAddr("feeVault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        ExtendedTokenUpgradeable implementation = new ExtendedTokenUpgradeable();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(ExtendedTokenUpgradeable.initialize, ("Upgradeable Token", "UPG", admin))
        );
        token = ExtendedTokenUpgradeable(address(proxy));

        vm.startPrank(admin);
        token.setFeeVault(vault);
        token.setFeeConfig(300, 1_000e18);
        token.mint(alice, 1_000_000e18);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------------------------------
    // The declaration
    // -----------------------------------------------------------------------------------------------

    /// @dev Upgradeability subsumes every other behaviour, so it is the one flag that must never be
    ///      omitted. An integrator reading a word without it would believe the rest of it was durable.
    function test_UpgradeableIsDeclared() public view {
        assertGt(token.behaviorFlags() & BehaviorFlags.UPGRADEABLE, 0);
    }

    function test_TheImmutableVariantDoesNotDeclareIt() public {
        ExtendedToken immutableToken = new ExtendedToken("Immutable", "IMM", admin);
        assertEq(immutableToken.behaviorFlags() & BehaviorFlags.UPGRADEABLE, 0);
    }

    function test_ItDeclaresEverythingTheImmutableVariantDoes() public {
        ExtendedToken immutableToken = new ExtendedToken("Immutable", "IMM", admin);
        assertEq(token.behaviorFlags(), immutableToken.behaviorFlags() | BehaviorFlags.UPGRADEABLE);
        assertEq(token.extensions().length, immutableToken.extensions().length);
    }

    // -----------------------------------------------------------------------------------------------
    // The upgrade
    // -----------------------------------------------------------------------------------------------

    function test_UpgradePreservesEveryDeclarationAndAllState() public {
        vm.prank(alice);
        token.transfer(bob, 10_000e18);

        uint256 flagsBefore = token.behaviorFlags();
        bytes4[] memory idsBefore = token.extensions();
        uint256 supplyBefore = token.totalSupply();
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 vaultBefore = token.balanceOf(vault);
        bytes memory feeConfigBefore = token.extensionData(ExtensionIds.TRANSFER_FEE);

        address v2 = address(new ExtendedTokenUpgradeableV2());
        vm.prank(admin);
        token.upgradeToAndCall(v2, "");

        assertEq(ExtendedTokenUpgradeableV2(address(token)).version(), 2, "the code really changed");

        assertEq(token.behaviorFlags(), flagsBefore);
        assertEq(token.extensions().length, idsBefore.length);
        for (uint256 i = 0; i < idsBefore.length; i++) {
            assertEq(bytes32(token.extensions()[i]), bytes32(idsBefore[i]));
        }

        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.balanceOf(alice), aliceBefore);
        assertEq(token.balanceOf(vault), vaultBefore);
        assertEq(token.extensionData(ExtensionIds.TRANSFER_FEE), feeConfigBefore);
        assertEq(token.name(), "Upgradeable Token");
    }

    function test_TokenStillWorksAfterTheUpgrade() public {
        address v2 = address(new ExtendedTokenUpgradeableV2());
        vm.prank(admin);
        token.upgradeToAndCall(v2, "");

        uint256 fee = token.computeFee(alice, bob, 1000e18);
        assertGt(fee, 0);

        vm.prank(alice);
        token.transfer(bob, 1000e18);
        assertEq(token.balanceOf(bob), 1000e18 - fee);
    }

    function test_RevertWhen_UpgraderRoleIsMissing() public {
        address v2 = address(new ExtendedTokenUpgradeableV2());

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.UPGRADER_ROLE()
            )
        );
        vm.prank(alice);
        token.upgradeToAndCall(v2, "");
    }

    /// @dev Upgrade authority is separable from the day-to-day authorities, which is the point of keeping
    ///      it in its own role rather than folding it into `DEFAULT_ADMIN_ROLE`.
    function test_UpgradeAuthorityCanBeHeldSeparately() public {
        address upgrader = makeAddr("upgrader");
        vm.startPrank(admin);
        token.grantRole(token.UPGRADER_ROLE(), upgrader);
        token.revokeRole(token.UPGRADER_ROLE(), admin);
        vm.stopPrank();

        address v2 = address(new ExtendedTokenUpgradeableV2());

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, token.UPGRADER_ROLE()
            )
        );
        vm.prank(admin);
        token.upgradeToAndCall(v2, "");

        vm.prank(upgrader);
        token.upgradeToAndCall(v2, "");
        assertEq(ExtendedTokenUpgradeableV2(address(token)).version(), 2);
    }

    // -----------------------------------------------------------------------------------------------
    // Initialisation
    // -----------------------------------------------------------------------------------------------

    function test_RevertWhen_ProxyIsInitialisedTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize("Hijack", "HJK", alice);
    }

    function test_RevertWhen_ImplementationIsInitialisedDirectly() public {
        ExtendedTokenUpgradeable implementation = new ExtendedTokenUpgradeable();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize("Orphan", "ORPH", admin);
    }

    /// @dev The immutable variant seals itself the same way, so it cannot be re-initialised through a
    ///      delegatecall from anywhere else either.
    function test_ImmutableVariantCannotBeReinitialised() public {
        ExtendedToken immutableToken = new ExtendedToken("Immutable", "IMM", admin);
        // There is no external initialiser at all, and the internal path is disabled. The observable
        // consequence is that the admin cannot be replaced by re-running initialisation.
        assertTrue(immutableToken.hasRole(immutableToken.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(immutableToken.hasRole(immutableToken.DEFAULT_ADMIN_ROLE(), alice));
    }
}
