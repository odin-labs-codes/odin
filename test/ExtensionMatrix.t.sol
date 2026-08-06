// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ERC20ExtensionCore} from "../src/extensions/ERC20ExtensionCore.sol";
import {IERC20NonTransferable} from "../src/interfaces/IERC20NonTransferable.sol";
import {BehaviorFlags} from "../src/libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../src/libraries/ExtensionIds.sol";

interface IComboToken {
    function mint(address to, uint256 value) external;
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function behaviorFlags() external view returns (uint256);
    function extensions() external view returns (bytes4[] memory);
    function hasExtension(bytes4 extensionId) external view returns (bool);
}

/**
 * @title ExtensionMatrixTest
 * @notice Every one of the 32 subsets of the five modules, assembled and deployed.
 *
 * @dev The permitted 20 must deploy, report exactly the extensions and behaviours they contain, and move
 *      value the way their modules say they should. The forbidden 12 must fail inside their own constructor
 *      with {ERC20ExtensionCore-ERC20IncompatibleBehaviors} — not at first transfer, not at first
 *      configuration, but before the contract exists at all. A token that could be deployed and only later
 *      discovered to be self-contradictory would already be in somebody's integration by then.
 *
 *      Contracts are deployed from their build artifacts rather than with `new`, so this test contract does
 *      not have to carry 32 sets of creation code in its own bytecode.
 */
contract ExtensionMatrixTest is Test {
    uint256 private constant BIT_METADATA = 1 << 0;
    uint256 private constant BIT_FEE = 1 << 1;
    uint256 private constant BIT_RESTRICTION = 1 << 2;
    uint256 private constant BIT_NON_TRANSFERABLE = 1 << 3;
    uint256 private constant BIT_HOOK = 1 << 4;

    uint256 private constant SUBSET_COUNT = 1 << 5;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function test_ForbiddenCombinationsRevertAtDeployment() public {
        uint256 checked;

        for (uint256 mask = 0; mask < SUBSET_COUNT; mask++) {
            if (!_isForbidden(mask)) continue;
            checked++;

            (address deployed, bytes memory err) = _tryDeploy(_contractName(mask));

            assertEq(deployed, address(0), string.concat(_contractName(mask), " should not deploy"));
            assertEq(
                bytes32(bytes4(err)),
                bytes32(ERC20ExtensionCore.ERC20IncompatibleBehaviors.selector),
                string.concat(_contractName(mask), " should name the conflict")
            );

            // The error carries which two behaviours collided, so the deployer is told what to fix.
            (uint256 first, uint256 second) = abi.decode(_body(err), (uint256, uint256));
            assertEq(first, BehaviorFlags.NON_TRANSFERABLE);
            assertTrue(second == BehaviorFlags.FEE_ON_TRANSFER || second == BehaviorFlags.TRANSFER_HOOK);
        }

        // Of the 16 subsets containing NON_TRANSFERABLE, the 4 that add neither FEE nor HOOK are fine.
        assertEq(checked, 12, "the forbidden set should be exactly twelve subsets");
    }

    function test_PermittedCombinationsDeployAndDeclareThemselvesAccurately() public {
        uint256 checked;

        for (uint256 mask = 0; mask < SUBSET_COUNT; mask++) {
            if (_isForbidden(mask)) continue;
            checked++;

            string memory name = _contractName(mask);
            (address deployed, bytes memory err) = _tryDeploy(name);
            assertTrue(deployed != address(0), string.concat(name, " should deploy"));
            assertEq(err.length, 0);

            IComboToken combo = IComboToken(deployed);

            assertEq(combo.extensions().length, _popcount(mask), string.concat(name, ": extension count"));
            assertEq(combo.behaviorFlags(), _expectedFlags(mask), string.concat(name, ": behaviour word"));

            assertEq(combo.hasExtension(ExtensionIds.ONCHAIN_METADATA), mask & BIT_METADATA != 0);
            assertEq(combo.hasExtension(ExtensionIds.TRANSFER_FEE), mask & BIT_FEE != 0);
            assertEq(combo.hasExtension(ExtensionIds.TRANSFER_RESTRICTION), mask & BIT_RESTRICTION != 0);
            assertEq(combo.hasExtension(ExtensionIds.NON_TRANSFERABLE), mask & BIT_NON_TRANSFERABLE != 0);
            assertEq(combo.hasExtension(ExtensionIds.TRANSFER_HOOK), mask & BIT_HOOK != 0);
        }

        assertEq(checked, 20, "the permitted set should be exactly twenty subsets");
    }

    function test_PermittedCombinationsMoveValueAsDeclared() public {
        for (uint256 mask = 0; mask < SUBSET_COUNT; mask++) {
            if (_isForbidden(mask)) continue;

            string memory name = _contractName(mask);
            (address deployed,) = _tryDeploy(name);
            IComboToken combo = IComboToken(deployed);

            combo.mint(alice, 1000e18);
            assertEq(combo.balanceOf(alice), 1000e18, string.concat(name, ": mint always works"));

            if (mask & BIT_NON_TRANSFERABLE != 0) {
                vm.expectRevert(IERC20NonTransferable.ERC20TransfersNotSupported.selector);
                vm.prank(alice);
                combo.transfer(bob, 100e18);
                assertEq(combo.balanceOf(bob), 0, string.concat(name, ": nothing moved"));
            } else {
                vm.prank(alice);
                assertTrue(combo.transfer(bob, 100e18));
                assertEq(combo.balanceOf(bob), 100e18, string.concat(name, ": value moved"));
                assertEq(combo.balanceOf(alice), 900e18);
            }
        }
    }

    // -----------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------

    /// @dev A token that cannot be transferred cannot charge a transfer fee or fire a transfer hook.
    function _isForbidden(uint256 mask) private pure returns (bool) {
        return mask & BIT_NON_TRANSFERABLE != 0 && (mask & BIT_FEE != 0 || mask & BIT_HOOK != 0);
    }

    function _expectedFlags(uint256 mask) private pure returns (uint256 flags) {
        if (mask & BIT_FEE != 0) flags |= BehaviorFlags.FEE_ON_TRANSFER;
        if (mask & BIT_RESTRICTION != 0) flags |= BehaviorFlags.PAUSABLE | BehaviorFlags.BLOCKLIST;
        if (mask & BIT_NON_TRANSFERABLE != 0) flags |= BehaviorFlags.NON_TRANSFERABLE;
        if (mask & BIT_HOOK != 0) flags |= BehaviorFlags.TRANSFER_HOOK;
        // The metadata module contributes nothing: it cannot change how a transfer behaves.
    }

    function _contractName(uint256 mask) private pure returns (string memory) {
        string[5] memory letters = ["M", "F", "R", "N", "H"];
        string memory suffix = "";
        for (uint256 i = 0; i < 5; i++) {
            // The lint rule flags `constant << variable` as a likely swapped shift; here it is the ordinary
            // bit test, and `i << 1` would be a different question entirely.
            // forge-lint: disable-next-line(incorrect-shift)
            if (mask & (1 << i) != 0) suffix = string.concat(suffix, letters[i]);
        }
        return bytes(suffix).length == 0 ? "Combo_None" : string.concat("Combo_", suffix);
    }

    function _popcount(uint256 mask) private pure returns (uint256 count) {
        for (uint256 i = 0; i < 5; i++) {
            // forge-lint: disable-next-line(incorrect-shift)
            if (mask & (1 << i) != 0) count++;
        }
    }

    /// @dev `create` from the build artifact, keeping the constructor's revert data instead of losing it.
    function _tryDeploy(string memory contractName) private returns (address addr, bytes memory err) {
        bytes memory creation = abi.encodePacked(
            vm.getCode(string.concat("Combinations.sol:", contractName)), abi.encode("Combo", "CMB")
        );
        err = "";

        assembly {
            addr := create(0, add(creation, 0x20), mload(creation))
            if iszero(addr) {
                let size := returndatasize()
                err := mload(0x40)
                mstore(err, size)
                returndatacopy(add(err, 0x20), 0, size)
                mstore(0x40, add(add(err, 0x20), and(add(size, 0x1f), not(0x1f))))
            }
        }
    }

    /// @dev Strips the four-byte selector, leaving the ABI-encoded error arguments.
    function _body(bytes memory data) private pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }
}
