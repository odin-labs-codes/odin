// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {ExtendedToken} from "../src/ExtendedToken.sol";
import {ExtendedTokenUpgradeable} from "../src/ExtendedTokenUpgradeable.sol";
import {ExtendedNFT} from "../src/erc721/ExtendedNFT.sol";
import {IBERCAccessControl} from "../src/interfaces/IBERCAccessControl.sol";

/**
 * @notice Pins the irreversible edge: after the burn, no administrator — including one granted the role
 *         before the burn — can restore or forcibly remove an authority.
 */
contract AdminBurnTest is Test {
    bytes32 private constant BERC_ACCESS_CONTROL_STORAGE_LOCATION =
        0x0e1d485d823a9719e7e6ecc31e2462cfee7fe832800ae1f2c3bdb2162a674800;

    address internal admin = makeAddr("admin");
    address internal secondAdmin = makeAddr("secondAdmin");
    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice");

    ExtendedToken internal token;
    ExtendedNFT internal nft;

    function setUp() public {
        token = new ExtendedToken("Extended", "EXT", admin);
        nft = new ExtendedNFT("Collection", "NFT", admin);
    }

    function test_AdminBurnIsDiscoverableThroughERC165() public view {
        assertTrue(token.supportsInterface(type(IBERCAccessControl).interfaceId));
        assertTrue(nft.supportsInterface(type(IBERCAccessControl).interfaceId));
    }

    function test_AdminBurnStateLivesAtItsDocumentedNamespace() public {
        assertEq(vm.load(address(token), BERC_ACCESS_CONTROL_STORAGE_LOCATION), bytes32(0));

        vm.prank(admin);
        token.burnAdminPrivileges();

        assertEq(vm.load(address(token), BERC_ACCESS_CONTROL_STORAGE_LOCATION), bytes32(uint256(1)));
    }

    function test_BurnPermanentlyLocksGrantAndForcedRevokeForEveryAdmin() public {
        bytes32 mintRole = token.MINT_ROLE();
        bytes32 seizeRole = token.SEIZE_ROLE();
        vm.startPrank(admin);
        token.grantRole(token.DEFAULT_ADMIN_ROLE(), secondAdmin);
        token.grantRole(mintRole, operator);
        token.burnAdminPrivileges();
        vm.stopPrank();

        assertTrue(token.adminPrivilegesBurned());
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        // The burn hides effective membership globally, so direct `onlyRole(DEFAULT_ADMIN_ROLE)` paths in
        // derived assemblies are closed too.
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), secondAdmin));

        vm.startPrank(secondAdmin);
        vm.expectRevert(IBERCAccessControl.BERCAdminPrivilegesBurned.selector);
        token.grantRole(seizeRole, secondAdmin);
        vm.expectRevert(IBERCAccessControl.BERCAdminPrivilegesBurned.selector);
        token.revokeRole(mintRole, operator);
        vm.expectRevert(IBERCAccessControl.BERCAdminPrivilegesAlreadyBurned.selector);
        token.burnAdminPrivileges();
        vm.stopPrank();

        vm.prank(operator);
        token.mint(alice, 1 ether);
        assertEq(token.balanceOf(alice), 1 ether, "existing operational authorities must keep working");
    }

    function test_AnOperationalAuthorityCanStillRenounceAfterAdminBurn() public {
        bytes32 mintRole = token.MINT_ROLE();
        vm.startPrank(admin);
        token.grantRole(mintRole, operator);
        token.burnAdminPrivileges();
        vm.stopPrank();

        vm.prank(operator);
        token.renounceRole(mintRole, operator);
        assertFalse(token.hasRole(mintRole, operator));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, mintRole)
        );
        vm.prank(operator);
        token.mint(alice, 1);
    }

    function test_RenounceAllRolesDropsEveryFungibleAuthorityAtomically() public {
        vm.prank(admin);
        token.renounceAllRoles();

        assertFalse(token.hasRole(token.MINT_ROLE(), admin));
        assertFalse(token.hasRole(token.SEIZE_ROLE(), admin));
        assertFalse(token.hasRole(token.METADATA_ROLE(), admin));
        assertFalse(token.hasRole(token.FEE_CONFIG_ROLE(), admin));
        assertFalse(token.hasRole(token.RESTRICTION_ROLE(), admin));
        assertFalse(token.hasRole(token.HOOK_CONFIG_ROLE(), admin));
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_RenounceAllRolesDropsEveryNonFungibleAuthorityAtomically() public {
        vm.prank(admin);
        nft.renounceAllRoles();

        assertFalse(nft.hasRole(nft.MINT_ROLE(), admin));
        assertFalse(nft.hasRole(nft.SEIZE_ROLE(), admin));
        assertFalse(nft.hasRole(nft.OPERATOR_POLICY_ROLE(), admin));
        assertFalse(nft.hasRole(nft.RESTRICTION_ROLE(), admin));
        assertFalse(nft.hasRole(nft.METADATA_ROLE(), admin));
        assertFalse(nft.hasRole(nft.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_UpgradeableVariantAlsoRenouncesItsUpgradeAuthority() public {
        ExtendedTokenUpgradeable implementation = new ExtendedTokenUpgradeable();
        ExtendedTokenUpgradeable upgradeable = ExtendedTokenUpgradeable(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(ExtendedTokenUpgradeable.initialize, ("Upgradeable", "UPG", admin))
                )
            )
        );

        vm.prank(admin);
        upgradeable.renounceAllRoles();

        assertFalse(upgradeable.hasRole(upgradeable.UPGRADER_ROLE(), admin));
        assertFalse(upgradeable.hasRole(upgradeable.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(upgradeable.hasRole(upgradeable.MINT_ROLE(), admin));
    }

    function test_NonAdminCannotBurnAdministration() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        token.burnAdminPrivileges();
    }
}
