// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ExtensionIds} from "../src/libraries/ExtensionIds.sol";
import {BaseTest} from "./BaseTest.sol";

/**
 * @title ConstantsTest
 * @notice Pins the two families of constants that are published outside the source tree.
 *
 * @dev The extension IDs appear in README.md and docs/INTEGRATION.md as literal hex, and integrators are
 *      invited to hard-code them. The ERC-7201 storage slots appear in the source as literals with the
 *      derivation only in a comment. Both are the kind of value that is copied once and never re-checked,
 *      so both get an assertion that recomputes them from first principles.
 *
 *      The slot assertions go further than comparing a literal to a formula: they read the live token's
 *      storage at the computed address and check that the value found there is the one the struct layout
 *      says should be there. That catches a wrong literal *and* a struct whose fields were reordered.
 */
contract ConstantsTest is BaseTest {
    function test_ExtensionIdsMatchThePublishedLiterals() public pure {
        assertEq(_b32(ExtensionIds.ONCHAIN_METADATA), _b32(0x1880c1f5), "onchainMetadata");
        assertEq(_b32(ExtensionIds.TRANSFER_FEE), _b32(0xe420f71e), "transferFee");
        assertEq(_b32(ExtensionIds.TRANSFER_RESTRICTION), _b32(0x72fd4318), "transferRestriction");
        assertEq(_b32(ExtensionIds.NON_TRANSFERABLE), _b32(0x2c0ebf42), "nonTransferable");
        assertEq(_b32(ExtensionIds.TRANSFER_HOOK), _b32(0xf71cd3fe), "transferHook");
    }

    function test_ExtensionIdsAreTheTopFourBytesOfTheirName() public pure {
        assertEq(_b32(ExtensionIds.ONCHAIN_METADATA), _name32("erc20.extension.onchainMetadata"));
        assertEq(_b32(ExtensionIds.TRANSFER_FEE), _name32("erc20.extension.transferFee"));
        assertEq(_b32(ExtensionIds.TRANSFER_RESTRICTION), _name32("erc20.extension.transferRestriction"));
        assertEq(_b32(ExtensionIds.NON_TRANSFERABLE), _name32("erc20.extension.nonTransferable"));
        assertEq(_b32(ExtensionIds.TRANSFER_HOOK), _name32("erc20.extension.transferHook"));
    }

    function test_RegistryStorageLivesAtItsNamespace() public {
        // First field is `bytes4[] ids`, so the base slot holds the array length: four modules registered.
        assertEq(uint256(vm.load(address(token), _erc7201("berc.storage.ExtensionRegistry"))), 4);
    }

    function test_MetadataStorageLivesAtItsNamespace() public {
        vm.startPrank(admin);
        token.setMetadata("issuer", "Acme");
        token.setMetadata("jurisdiction", "KR");
        vm.stopPrank();

        // First field is `string[] keys`.
        assertEq(uint256(vm.load(address(token), _erc7201("berc.storage.OnchainMetadata"))), 2);
    }

    function test_TransferFeeStorageLivesAtItsNamespace() public {
        _setFee(750, 0);

        // `uint16 basisPoints` and `address feeVault` share the first slot, low-order field first.
        uint256 packed = uint256(vm.load(address(token), _erc7201("berc.storage.TransferFee")));
        assertEq(uint16(packed), 750);
        assertEq(address(uint160(packed >> 16)), vault);
    }

    function test_RestrictionStorageLivesAtItsNamespace() public {
        _setPaused(true);
        assertEq(uint256(vm.load(address(token), _erc7201("berc.storage.TransferRestriction"))), 1);
    }

    function test_HookStorageLivesAtItsNamespace() public {
        address hook = address(new StorageProbeHook());
        _setHook(hook, 55_000);

        // `address hook` then `uint32 gasLimit`, packed into the first slot.
        uint256 packed = uint256(vm.load(address(token), _erc7201("berc.storage.TransferHook")));
        assertEq(address(uint160(packed)), hook);
        assertEq(uint32(packed >> 160), 55_000);
    }

    function _erc7201(string memory namespace) private pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(namespace))) - 1)) & ~bytes32(uint256(0xff));
    }

    /// @dev `bytes4` has no `assertEq` overload and does not implicitly widen; right-pad it explicitly.
    function _b32(bytes4 value) private pure returns (bytes32) {
        return bytes32(value);
    }

    function _name32(string memory name) private pure returns (bytes32) {
        return bytes32(bytes4(keccak256(bytes(name))));
    }
}

/// @dev Any contract will do; the hook only has to have code for {setTransferHook} to accept it.
contract StorageProbeHook {
    fallback() external {}
}
