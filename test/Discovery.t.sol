// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Extensions} from "../src/interfaces/IERC20Extensions.sol";
import {ExtensionIds} from "../src/libraries/ExtensionIds.sol";

import {BaseTest} from "./BaseTest.sol";

/// @dev The discovery surface is the whole point of the framework, so it gets its own suite rather than
///      being checked in passing by the module tests.
contract DiscoveryTest is BaseTest {
    /// @dev An id no assembly in this repo installs, so it stands in for "an extension you do not have".
    bytes4 private constant ABSENT = bytes4(keccak256("erc20.extension.notARealExtension"));

    function test_InstalledExtensionsAreReported() public view {
        bytes4[] memory ids = token.extensions();

        assertEq(ids.length, 3);
        assertEq(ids[0], ExtensionIds.ONCHAIN_METADATA);
        assertEq(ids[1], ExtensionIds.TRANSFER_FEE);
        assertEq(ids[2], ExtensionIds.TRANSFER_RESTRICTION);
        assertTrue(token.hasExtension(ExtensionIds.ONCHAIN_METADATA));
        assertTrue(token.hasExtension(ExtensionIds.TRANSFER_FEE));
        assertTrue(token.hasExtension(ExtensionIds.TRANSFER_RESTRICTION));
    }

    function test_UninstalledExtensionIsNotReported() public view {
        assertFalse(token.hasExtension(ABSENT));
    }

    function test_ExtensionDataReportsUriAndKeyCount() public {
        vm.startPrank(admin);
        token.setTokenURI("ipfs://document");
        token.setMetadata("a", "1");
        vm.stopPrank();

        (string memory uri, uint256 keyCount) =
            abi.decode(token.extensionData(ExtensionIds.ONCHAIN_METADATA), (string, uint256));

        assertEq(uri, "ipfs://document");
        assertEq(keyCount, 1);
    }

    function test_ConfiguringEmitsTheWholeConfiguration() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit IERC20Extensions.ExtensionConfigured(ExtensionIds.ONCHAIN_METADATA, abi.encode("ipfs://doc", uint256(0)));

        vm.prank(admin);
        token.setTokenURI("ipfs://doc");
    }

    function test_RevertWhen_ReadingDataForAnUninstalledExtension() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Extensions.ERC20ExtensionNotEnabled.selector, ABSENT));
        token.extensionData(ABSENT);
    }
}
