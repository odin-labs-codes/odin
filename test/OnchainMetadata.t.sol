// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IERC20OnchainMetadata} from "../src/interfaces/IERC20OnchainMetadata.sol";
import {ExtensionIds} from "../src/libraries/ExtensionIds.sol";
import {BaseTest} from "./BaseTest.sol";

contract OnchainMetadataTest is BaseTest {
    /// @dev Paging exists so an indexer never has to call `metadataKeys()` on a store it does not control.
    function test_KeysCanBePagedWithoutReadingTheWholeStore() public {
        vm.startPrank(admin);
        token.setMetadata("one", "1");
        token.setMetadata("two", "2");
        token.setMetadata("three", "3");
        vm.stopPrank();

        assertEq(token.metadataKeyCount(), 3);

        string[] memory paged = new string[](token.metadataKeyCount());
        for (uint256 i = 0; i < paged.length; ++i) {
            paged[i] = token.metadataKeyAt(i);
        }

        string[] memory whole = token.metadataKeys();
        assertEq(paged.length, whole.length);
        for (uint256 i = 0; i < whole.length; ++i) {
            assertEq(paged[i], whole[i], "paging must agree with the bulk read");
        }

        vm.expectRevert(abi.encodeWithSelector(IERC20OnchainMetadata.ERC20MetadataIndexOutOfBounds.selector, 3, 3));
        token.metadataKeyAt(3);
    }

    function test_SetAndReadBack() public {
        vm.prank(admin);
        token.setMetadata("issuer", "Acme Securities");

        assertEq(token.getMetadata("issuer"), "Acme Securities");
    }

    function test_MissingKeyReadsAsEmptyRatherThanReverting() public view {
        assertEq(token.getMetadata("nothing-here"), "");
    }

    function test_KeysAreEnumerable() public {
        vm.startPrank(admin);
        token.setMetadata("issuer", "Acme");
        token.setMetadata("jurisdiction", "KR");
        token.setMetadata("isin", "KR7005930003");
        vm.stopPrank();

        string[] memory keys = token.metadataKeys();
        assertEq(keys.length, 3);
        assertEq(keys[0], "issuer");
        assertEq(keys[1], "jurisdiction");
        assertEq(keys[2], "isin");
    }

    function test_OverwritingDoesNotDuplicateTheKey() public {
        vm.startPrank(admin);
        token.setMetadata("issuer", "Acme");
        token.setMetadata("issuer", "Acme Holdings");
        vm.stopPrank();

        assertEq(token.metadataKeys().length, 1);
        assertEq(token.getMetadata("issuer"), "Acme Holdings");
    }

    function test_EmptyValueKeepsTheKeyPresent() public {
        vm.prank(admin);
        token.setMetadata("note", "");

        assertEq(token.metadataKeys().length, 1);
        assertEq(token.getMetadata("note"), "");
    }

    function test_RemoveDropsTheKeyAndItsValue() public {
        vm.startPrank(admin);
        token.setMetadata("a", "1");
        token.setMetadata("b", "2");
        token.setMetadata("c", "3");
        token.removeMetadata("b");
        vm.stopPrank();

        assertEq(token.metadataKeys().length, 2);
        assertEq(token.getMetadata("b"), "");

        // Swap-and-pop: the last key moved into the gap, and the survivors are still both reachable.
        string[] memory keys = token.metadataKeys();
        assertEq(keys[0], "a");
        assertEq(keys[1], "c");
        assertEq(token.getMetadata("a"), "1");
        assertEq(token.getMetadata("c"), "3");
    }

    function test_RemoveTheLastKey() public {
        vm.startPrank(admin);
        token.setMetadata("only", "value");
        token.removeMetadata("only");
        vm.stopPrank();

        assertEq(token.metadataKeys().length, 0);
    }

    /// @dev Remove-then-re-add must not leave a stale index behind.
    function test_ReAddingAfterRemovalWorks() public {
        vm.startPrank(admin);
        token.setMetadata("a", "1");
        token.setMetadata("b", "2");
        token.removeMetadata("a");
        token.setMetadata("a", "3");
        vm.stopPrank();

        assertEq(token.metadataKeys().length, 2);
        assertEq(token.getMetadata("a"), "3");
        assertEq(token.getMetadata("b"), "2");
    }

    function test_RevertWhen_RemovingAKeyThatIsNotThere() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20OnchainMetadata.ERC20MetadataKeyNotFound.selector, "ghost"));
        vm.prank(admin);
        token.removeMetadata("ghost");
    }

    function test_RevertWhen_KeyIsEmpty() public {
        vm.expectRevert(IERC20OnchainMetadata.ERC20MetadataInvalidKey.selector);
        vm.prank(admin);
        token.setMetadata("", "value");
    }

    function test_TokenUriIsSeparateFromTheKeyValueStore() public {
        vm.startPrank(admin);
        token.setTokenURI("ipfs://QmExample");
        token.setMetadata("issuer", "Acme");
        vm.stopPrank();

        assertEq(token.tokenURI(), "ipfs://QmExample");
        // The URI is not a key, so it does not appear in the enumeration.
        assertEq(token.metadataKeys().length, 1);
        assertEq(token.metadataKeys()[0], "issuer");
    }

    function test_ExtensionDataReportsUriAndKeyCount() public {
        vm.startPrank(admin);
        token.setTokenURI("https://example.com/meta.json");
        token.setMetadata("a", "1");
        token.setMetadata("b", "2");
        vm.stopPrank();

        (string memory uri, uint256 keyCount) =
            abi.decode(token.extensionData(ExtensionIds.ONCHAIN_METADATA), (string, uint256));
        assertEq(uri, "https://example.com/meta.json");
        assertEq(keyCount, 2);
    }

    /**
     * @dev Both the filterable hash and the readable key are checked, because an `indexed string` puts
     *      only its hash in the log — an indexer that saw one of those could filter for a key it already
     *      knew and never learn the name of one it did not.
     */
    function test_Events() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit IERC20OnchainMetadata.MetadataUpdated(keccak256(bytes("issuer")), "issuer", "Acme");
        vm.prank(admin);
        token.setMetadata("issuer", "Acme");

        vm.expectEmit(true, false, false, true, address(token));
        emit IERC20OnchainMetadata.MetadataRemoved(keccak256(bytes("issuer")), "issuer");
        vm.prank(admin);
        token.removeMetadata("issuer");

        vm.expectEmit(false, false, false, true, address(token));
        emit IERC20OnchainMetadata.TokenURIUpdated("ipfs://x");
        vm.prank(admin);
        token.setTokenURI("ipfs://x");
    }

    function test_MetadataDeclaresNoBehaviour() public view {
        // The module is installed and contributes nothing to the behaviour word: it cannot change how a
        // transfer behaves, so there is nothing for an integrator to defend against.
        assertTrue(token.hasExtension(ExtensionIds.ONCHAIN_METADATA));
    }

    function test_RevertWhen_CallerLacksTheMetadataRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.METADATA_ROLE()
            )
        );
        vm.prank(alice);
        token.setMetadata("issuer", "Acme");
    }
}
