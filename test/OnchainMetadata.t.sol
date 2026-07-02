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
