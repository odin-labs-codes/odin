// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccountState} from "../src/interfaces/IERC20AccountState.sol";
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

        assertEq(ids.length, 4);
        assertEq(ids[0], ExtensionIds.ONCHAIN_METADATA);
        assertEq(ids[1], ExtensionIds.TRANSFER_FEE);
        assertEq(ids[2], ExtensionIds.TRANSFER_RESTRICTION);
        assertEq(ids[3], ExtensionIds.TRANSFER_HOOK);
        assertTrue(token.hasExtension(ExtensionIds.ONCHAIN_METADATA));
        assertTrue(token.hasExtension(ExtensionIds.TRANSFER_FEE));
        assertTrue(token.hasExtension(ExtensionIds.TRANSFER_RESTRICTION));
    }

    function test_UninstalledExtensionIsNotReported() public view {
        assertFalse(token.hasExtension(ABSENT));
    }

    function test_MintAndSeizeAreAlwaysDeclared() public view {
        uint256 flags = token.behaviorFlags();

        assertTrue(flags & (1 << 7) != 0, "MINTABLE");
        assertTrue(flags & (1 << 8) != 0, "SEIZABLE");
    }

    function test_ImmutableTokenDoesNotDeclareUpgradeable() public view {
        assertEq(token.behaviorFlags() & (1 << 6), 0);
    }

    function test_AccountStateAnswersForEveryModuleAtOnce() public {
        vm.startPrank(admin);
        token.setFrozen(alice, true);
        token.setFeeExempt(alice, true);
        vm.stopPrank();

        AccountState memory state = token.accountState(alice);

        assertTrue(state.frozen);
        assertTrue(state.feeExempt);
        assertEq(state.configuredAt, uint64(block.timestamp));
    }

    function test_AnUntouchedAccountReadsAsNeutralRatherThanReverting() public view {
        AccountState memory state = token.accountState(carol);

        assertFalse(state.frozen);
        assertFalse(state.feeExempt);
        assertEq(state.configuredAt, 0);
    }

    function test_RotatingTheVaultTouchesBothAddresses() public {
        vm.warp(1_000_000);
        vm.prank(admin);
        token.setFeeVault(carol);

        assertEq(token.accountState(carol).configuredAt, 1_000_000);
        assertEq(token.accountState(vault).configuredAt, 1_000_000);
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
