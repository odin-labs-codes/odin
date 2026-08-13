// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20ExtensionCore} from "../src/extensions/ERC20ExtensionCore.sol";
import {IERC20Extensions} from "../src/interfaces/IERC20Extensions.sol";
import {BehaviorFlags} from "../src/libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../src/libraries/ExtensionIds.sol";
import {BaseTest} from "./BaseTest.sol";
import {UnsealedToken} from "./mocks/UnsealedToken.sol";

/**
 * @title DiscoveryTest
 * @notice The declaration layer: what a token says about itself, and the promise that it keeps saying it.
 */
contract DiscoveryTest is BaseTest {
    function test_ExtensionsListsExactlyWhatWasAssembled() public view {
        bytes4[] memory ids = token.extensions();

        assertEq(ids.length, 4);
        assertEq(bytes32(ids[0]), bytes32(ExtensionIds.ONCHAIN_METADATA));
        assertEq(bytes32(ids[1]), bytes32(ExtensionIds.TRANSFER_FEE));
        assertEq(bytes32(ids[2]), bytes32(ExtensionIds.TRANSFER_RESTRICTION));
        assertEq(bytes32(ids[3]), bytes32(ExtensionIds.TRANSFER_HOOK));
    }

    function test_HasExtensionAgreesWithTheList() public view {
        assertTrue(token.hasExtension(ExtensionIds.ONCHAIN_METADATA));
        assertTrue(token.hasExtension(ExtensionIds.TRANSFER_FEE));
        assertTrue(token.hasExtension(ExtensionIds.TRANSFER_RESTRICTION));
        assertTrue(token.hasExtension(ExtensionIds.TRANSFER_HOOK));

        assertFalse(token.hasExtension(ExtensionIds.NON_TRANSFERABLE));
        assertFalse(token.hasExtension(bytes4(0x12345678)));
    }

    function test_BehaviorFlagsAreTheUnionOfTheInstalledModulesAndTheSupplyPowers() public view {
        uint256 expected = BehaviorFlags.FEE_ON_TRANSFER | BehaviorFlags.PAUSABLE | BehaviorFlags.BLOCKLIST
            | BehaviorFlags.TRANSFER_HOOK | BehaviorFlags.MINTABLE | BehaviorFlags.SEIZABLE;

        assertEq(token.behaviorFlags(), expected);
        assertEq(token.behaviorFlags() & BehaviorFlags.NON_TRANSFERABLE, 0);
        assertEq(token.behaviorFlags() & BehaviorFlags.UPGRADEABLE, 0, "no proxy in front of this one");
        assertEq(token.behaviorFlags() & BehaviorFlags.REBASING, 0);
    }

    /**
     * @dev The supply powers come from the assembly, not from any extension, so they are declared even by
     *      a token that installs nothing. Without them a token could report `0` — which the vocabulary
     *      defines as indistinguishable from a plain ERC-20 — while diluting every holder at will.
     */
    function test_SupplyPowersAreDeclaredAndAreReal() public {
        assertGt(token.behaviorFlags() & BehaviorFlags.MINTABLE, 0);
        assertGt(token.behaviorFlags() & BehaviorFlags.SEIZABLE, 0);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(admin);
        token.mint(carol, 1_000e18);
        assertEq(token.totalSupply(), supplyBefore + 1_000e18, "MINTABLE is not decorative");

        // And the seizure the flag warns about: a balance destroyed without its holder's involvement.
        vm.prank(admin);
        token.burn(alice, 1_000e18);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 1_000e18, "SEIZABLE is not decorative either");
    }

    /// @dev The cacheability claim: configuration moves, declarations do not.
    function test_BehaviorFlagsDoNotMoveWhenConfigurationDoes() public {
        uint256 before = token.behaviorFlags();

        _setFee(1000, 1e18);
        _setPaused(true);
        _setFrozen(alice, true);
        vm.prank(admin);
        token.setFeeExempt(bob, true);

        assertEq(token.behaviorFlags(), before);
        assertEq(token.extensions().length, 4);
    }

    function test_FlagIsSetEvenWhileTheFeeIsZero() public view {
        // The rate starts at zero, and the flag is set anyway: the authority can raise it at any time, and
        // an integrator who cached "no fee" from a zero rate would be wrong the moment it moves.
        assertEq(token.feeBasisPoints(), 0);
        assertGt(token.behaviorFlags() & BehaviorFlags.FEE_ON_TRANSFER, 0);
    }

    function test_ExtensionDataForEachInstalledModule() public {
        // Metadata: URI plus the number of keys.
        (string memory uri, uint256 keyCount) =
            abi.decode(token.extensionData(ExtensionIds.ONCHAIN_METADATA), (string, uint256));
        assertEq(uri, "");
        assertEq(keyCount, 0);

        // Restriction: just the pause flag.
        assertFalse(abi.decode(token.extensionData(ExtensionIds.TRANSFER_RESTRICTION), (bool)));

        // Hook: target and gas budget.
        (address hook, uint32 gasLimit) =
            abi.decode(token.extensionData(ExtensionIds.TRANSFER_HOOK), (address, uint32));
        assertEq(hook, address(0));
        assertEq(gasLimit, 0);
    }

    function test_RevertWhen_ExtensionDataForAModuleThatIsNotInstalled() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Extensions.ERC20ExtensionNotEnabled.selector, ExtensionIds.NON_TRANSFERABLE)
        );
        token.extensionData(ExtensionIds.NON_TRANSFERABLE);
    }

    function test_AccountStateAggregatesEveryModule() public {
        _setFrozen(carol, true);
        vm.prank(admin);
        token.setFeeExempt(carol, true);

        assertTrue(token.accountState(carol).frozen);
        assertTrue(token.accountState(carol).feeExempt);
        assertEq(token.accountState(carol).configuredAt, uint64(block.timestamp));

        assertFalse(token.accountState(bob).frozen);
        assertFalse(token.accountState(bob).feeExempt);
    }

    /// @dev An assembly that forgets to seal loses its whole discovery surface, loudly.
    function test_RevertWhen_DiscoveryIsReadBeforeSealing() public {
        UnsealedToken unsealed = new UnsealedToken();

        vm.expectRevert(ERC20ExtensionCore.ERC20ExtensionSetNotSealed.selector);
        unsealed.extensions();

        vm.expectRevert(ERC20ExtensionCore.ERC20ExtensionSetNotSealed.selector);
        unsealed.behaviorFlags();

        vm.expectRevert(ERC20ExtensionCore.ERC20ExtensionSetNotSealed.selector);
        unsealed.hasExtension(ExtensionIds.TRANSFER_FEE);

        vm.expectRevert(ERC20ExtensionCore.ERC20ExtensionSetNotSealed.selector);
        unsealed.extensionData(ExtensionIds.TRANSFER_FEE);
    }

    /// @dev No path re-opens registration once the token is live.
    function test_RegistrationIsUnreachableAfterDeployment() public {
        // Every registration entry point is `onlyInitializing`, and `_disableInitializers()` ran in the
        // constructor, so there is no call sequence that reaches one. The observable consequence is that
        // the extension set is identical before and after arbitrary use of the token.
        bytes4[] memory before = token.extensions();

        vm.prank(alice);
        token.transfer(bob, 1e18);
        _setFee(500, 1e18);
        _setPaused(true);
        _setPaused(false);

        bytes4[] memory current = token.extensions();
        assertEq(current.length, before.length);
        for (uint256 i = 0; i < before.length; i++) {
            assertEq(bytes32(current[i]), bytes32(before[i]));
        }
    }
}
