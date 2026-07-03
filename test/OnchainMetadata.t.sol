// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IERC20OnchainMetadata} from "../src/interfaces/IERC20OnchainMetadata.sol";

import {BaseTest} from "./BaseTest.sol";

contract OnchainMetadataTest is BaseTest {
    function test_SetAndReadBack() public {
        vm.prank(admin);
        token.setMetadata("website", "https://example.com");

        assertEq(token.getMetadata("website"), "https://example.com");
    }

    function test_MissingKeyReadsAsEmptyRatherThanReverting() public view {
        assertEq(token.getMetadata("nothing-here"), "");
    }

    function test_EmptyValueKeepsTheKeyPresent() public {
        vm.startPrank(admin);
        token.setMetadata("issuer", "Acme");
        token.setMetadata("issuer", "");
        vm.stopPrank();

        assertEq(token.getMetadata("issuer"), "");
    }

    function test_KeysAreEnumerable() public {
        vm.startPrank(admin);
        token.setMetadata("a", "1");
        token.setMetadata("b", "2");
        vm.stopPrank();

        assertEq(token.metadataKeyCount(), 2);
        assertEq(token.metadataKeyAt(0), "a");
        assertEq(token.metadataKeyAt(1), "b");
        assertEq(token.metadataKeys().length, 2);
    }

    function test_OverwritingDoesNotDuplicateTheKey() public {
        vm.startPrank(admin);
        token.setMetadata("a", "1");
        token.setMetadata("a", "2");
        vm.stopPrank();

        assertEq(token.metadataKeyCount(), 1);
        assertEq(token.getMetadata("a"), "2");
    }

    function test_RemoveDropsTheKeyAndItsValue() public {
        vm.startPrank(admin);
        token.setMetadata("a", "1");
        token.setMetadata("b", "2");
        token.removeMetadata("a");
        vm.stopPrank();

        assertEq(token.metadataKeyCount(), 1);
        assertEq(token.metadataKeyAt(0), "b");
        assertEq(token.getMetadata("a"), "");
    }

    function test_RemoveTheLastKey() public {
        vm.startPrank(admin);
        token.setMetadata("a", "1");
        token.removeMetadata("a");
        vm.stopPrank();

        assertEq(token.metadataKeyCount(), 0);
    }

    function test_ReAddingAfterRemovalWorks() public {
        vm.startPrank(admin);
        token.setMetadata("a", "1");
        token.removeMetadata("a");
        token.setMetadata("a", "3");
        vm.stopPrank();

        assertEq(token.metadataKeyCount(), 1);
        assertEq(token.getMetadata("a"), "3");
    }

    function test_RevertWhen_RemovingAKeyThatIsNotThere() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20OnchainMetadata.ERC20MetadataKeyNotFound.selector, "nope"));
        vm.prank(admin);
        token.removeMetadata("nope");
    }

    function test_RevertWhen_KeyIndexIsPastTheEnd() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20OnchainMetadata.ERC20MetadataIndexOutOfBounds.selector, 0, 0));
        token.metadataKeyAt(0);
    }

    function test_TokenUriIsSeparateFromTheKeyValueStore() public {
        vm.startPrank(admin);
        token.setTokenURI("ipfs://document");
        token.setMetadata("website", "https://example.com");
        vm.stopPrank();

        assertEq(token.tokenURI(), "ipfs://document");
        assertEq(token.metadataKeyCount(), 1);
    }

    function test_Events() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit IERC20OnchainMetadata.MetadataUpdated(keccak256("website"), "website", "https://example.com");

        vm.prank(admin);
        token.setMetadata("website", "https://example.com");
    }

    function test_RevertWhen_KeyIsEmpty() public {
        vm.expectRevert(IERC20OnchainMetadata.ERC20MetadataInvalidKey.selector);
        vm.prank(admin);
        token.setMetadata("", "value");
    }

    function test_RevertWhen_CallerLacksTheMetadataRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.METADATA_ROLE()
            )
        );
        vm.prank(alice);
        token.setMetadata("website", "https://example.com");
    }
}
