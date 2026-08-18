// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ERC721ExtensionCore} from "../../src/erc721/ERC721ExtensionCore.sol";
import {ERC721NonTransferable} from "../../src/erc721/ERC721NonTransferable.sol";
import {ExtendedNFT, SoulboundNFT} from "../../src/erc721/ExtendedNFT.sol";
import {ExtendedNFTBase} from "../../src/erc721/ExtendedNFTBase.sol";
import {IERC721OperatorRestriction} from "../../src/interfaces/IERC721OperatorRestriction.sol";
import {BehaviorFlags} from "../../src/libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../../src/libraries/ExtensionIds.sol";

/**
 * @title MarketplaceRouter
 * @notice What a marketplace's settlement contract does, reduced to the one call that matters.
 *
 * @dev It holds no approval logic of its own — the seller approves it the normal way and it calls
 *      `transferFrom`. That is exactly the shape an operator policy screens, and the reason this mock
 *      exists rather than the test calling `transferFrom` itself: when the test is the caller, `msg.sender`
 *      is an EOA and the interesting case never arises.
 */
contract MarketplaceRouter {
    /// @notice Settles a sale the naive way: no questions asked, and a revert the caller cannot explain.
    function settle(IERC721 collection, address seller, address buyer, uint256 tokenId) external {
        collection.transferFrom(seller, buyer, tokenId);
    }

    /**
     * @notice Settles only after asking the collection whether this contract is allowed to.
     * @dev The whole point of the extension. One `view` before committing, and a refusal that names itself
     *      instead of surfacing as a failed settlement.
     */
    function settleChecked(IERC721 collection, address seller, address buyer, uint256 tokenId) external {
        if (!IERC721OperatorRestriction(address(collection)).isOperatorAllowed(address(this))) {
            revert CannotSettleHere(address(collection));
        }
        collection.transferFrom(seller, buyer, tokenId);
    }

    error CannotSettleHere(address collection);
}

contract ExtendedNFTTest is Test {
    ExtendedNFT internal nft;
    MarketplaceRouter internal router;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant TOKEN_ID = 42;

    function setUp() public {
        nft = new ExtendedNFT("Extended", "EXT", admin);
        router = new MarketplaceRouter();

        vm.prank(admin);
        nft.mint(alice, TOKEN_ID);

        // The seller approves the marketplace the ordinary way. Nothing here is framework-specific.
        vm.prank(alice);
        nft.setApprovalForAll(address(router), true);
    }

    // -----------------------------------------------------------------------------------------------
    // Backward compatibility
    // -----------------------------------------------------------------------------------------------

    /// @dev A wallet that has never heard of this framework must see an ordinary ERC-721.
    function test_LooksLikeAPlainERC721() public view {
        assertEq(nft.name(), "Extended");
        assertEq(nft.symbol(), "EXT");
        assertEq(nft.ownerOf(TOKEN_ID), alice);
        assertEq(nft.balanceOf(alice), 1);
        assertTrue(nft.supportsInterface(type(IERC721).interfaceId));
        assertTrue(nft.supportsInterface(type(IERC165).interfaceId));
        assertTrue(nft.supportsInterface(type(IAccessControl).interfaceId));
    }

    function test_OwnerCanTransferWithoutAnyPolicyInvolvement() public {
        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ID);
        assertEq(nft.ownerOf(TOKEN_ID), bob);
    }

    // -----------------------------------------------------------------------------------------------
    // Declaration
    // -----------------------------------------------------------------------------------------------

    function test_DeclaresItsBehaviourInOneWord() public view {
        assertEq(
            nft.behaviorFlags(),
            BehaviorFlags.OPERATOR_RESTRICTED | BehaviorFlags.PAUSABLE | BehaviorFlags.BLOCKLIST
                | BehaviorFlags.METADATA_MUTABLE | BehaviorFlags.MINTABLE | BehaviorFlags.SEIZABLE
        );
    }

    /// @dev The flag is set because the module is installed, not because it is currently enforcing.
    function test_DeclaresTheFlagEvenWhileEnforcementIsOff() public view {
        assertFalse(nft.operatorAllowlistEnforced());
        assertGt(nft.behaviorFlags() & BehaviorFlags.OPERATOR_RESTRICTED, 0);
    }

    function test_ReportsItsExtensionSet() public view {
        bytes4[] memory ids = nft.extensions();
        assertEq(ids.length, 3);
        assertEq(ids[0], ExtensionIds.NFT_OPERATOR_RESTRICTION);
        assertEq(ids[1], ExtensionIds.NFT_TRANSFER_RESTRICTION);
        assertEq(ids[2], ExtensionIds.NFT_MUTABLE_METADATA);
        assertTrue(nft.hasExtension(ExtensionIds.NFT_OPERATOR_RESTRICTION));
        assertFalse(nft.hasExtension(ExtensionIds.NFT_NON_TRANSFERABLE));
    }

    function test_ExtensionDataReportsWhetherThePolicyIsLive() public {
        assertEq(nft.extensionData(ExtensionIds.NFT_OPERATOR_RESTRICTION), abi.encode(false));

        vm.prank(admin);
        nft.setOperatorAllowlistEnforced(true);

        assertEq(nft.extensionData(ExtensionIds.NFT_OPERATOR_RESTRICTION), abi.encode(true));
    }

    function test_RevertWhen_ExtensionDataIsAskedForAnUninstalledExtension() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721ExtensionCore.ERC721ExtensionNotEnabled.selector, ExtensionIds.NFT_NON_TRANSFERABLE
            )
        );
        nft.extensionData(ExtensionIds.NFT_NON_TRANSFERABLE);
    }

    /// @dev The fungible and non-fungible ids for the same idea are different on purpose.
    function test_NonFungibleExtensionIdsAreDistinctFromTheFungibleOnes() public pure {
        assertTrue(ExtensionIds.NFT_NON_TRANSFERABLE != ExtensionIds.NON_TRANSFERABLE);
    }

    // -----------------------------------------------------------------------------------------------
    // The existence proof: a marketplace that asks first
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev The failure this framework exists to prevent. The marketplace holds a valid approval, the seller
     *      owns the token, and settlement still reverts — for a reason no simulation of the *owner's*
     *      transfer would ever have surfaced.
     */
    function test_NaiveMarketplaceFailsAtSettlementWithAValidApproval() public {
        vm.prank(admin);
        nft.setOperatorAllowlistEnforced(true);

        assertTrue(nft.isApprovedForAll(alice, address(router)), "the approval is real");

        vm.expectRevert(
            abi.encodeWithSelector(IERC721OperatorRestriction.ERC721OperatorNotAllowed.selector, address(router))
        );
        router.settle(IERC721(address(nft)), alice, bob, TOKEN_ID);
    }

    /// @dev And the same marketplace, one `view` call earlier, refuses to list rather than failing to settle.
    function test_MarketplaceThatAsksFirstLearnsItCannotSettle() public {
        vm.prank(admin);
        nft.setOperatorAllowlistEnforced(true);

        assertFalse(nft.isOperatorAllowed(address(router)));

        vm.expectRevert(abi.encodeWithSelector(MarketplaceRouter.CannotSettleHere.selector, address(nft)));
        router.settleChecked(IERC721(address(nft)), alice, bob, TOKEN_ID);
    }

    function test_AllowlistedMarketplaceSettlesNormally() public {
        vm.startPrank(admin);
        nft.setOperatorAllowlistEnforced(true);
        nft.setOperatorAllowed(address(router), true);
        vm.stopPrank();

        assertTrue(nft.isOperatorAllowed(address(router)));

        router.settleChecked(IERC721(address(nft)), alice, bob, TOKEN_ID);
        assertEq(nft.ownerOf(TOKEN_ID), bob);
    }

    // -----------------------------------------------------------------------------------------------
    // Policy semantics
    // -----------------------------------------------------------------------------------------------

    /// @dev Answering `true` for everyone while enforcement is off is what lets a caller make one call.
    function test_EveryOperatorIsAllowedWhileEnforcementIsOff() public {
        assertTrue(nft.isOperatorAllowed(address(router)));
        assertTrue(nft.isOperatorAllowed(makeAddr("anyone")));
    }

    function test_OperatorsCanBeApprovedEvenWhenTheyCannotTransfer() public {
        vm.startPrank(admin);
        nft.setOperatorAllowlistEnforced(true);
        vm.stopPrank();

        address barred = makeAddr("barred");
        vm.prank(alice);
        nft.setApprovalForAll(barred, true);

        assertTrue(nft.isApprovedForAll(alice, barred), "approval is deliberately not gated");
        assertFalse(nft.isOperatorAllowed(barred), "but the transfer is");
    }

    /// @dev A policy that could stop an owner would be a soulbound token wearing a disguise.
    function test_OwnerIsNeverScreened() public {
        vm.startPrank(admin);
        nft.setOperatorAllowlistEnforced(true);
        vm.stopPrank();

        assertFalse(nft.isOperatorAllowed(alice));

        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ID);
        assertEq(nft.ownerOf(TOKEN_ID), bob);
    }

    /// @dev An allowlist that could block minting would be a pause, which is a different flag.
    function test_MintAndBurnAreNeverScreened() public {
        vm.startPrank(admin);
        nft.setOperatorAllowlistEnforced(true);
        nft.mint(bob, 43);
        nft.burn(43);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(43)));
        nft.ownerOf(43);
    }

    /// @dev Enforcement and membership are separate so a list can be built before it starts being applied.
    function test_AllowlistSurvivesEnforcementBeingToggled() public {
        vm.startPrank(admin);
        nft.setOperatorAllowed(address(router), true);
        nft.setOperatorAllowlistEnforced(true);
        nft.setOperatorAllowlistEnforced(false);
        nft.setOperatorAllowlistEnforced(true);
        vm.stopPrank();

        assertTrue(nft.isOperatorAllowed(address(router)), "membership is not cleared by the switch");
    }

    // -----------------------------------------------------------------------------------------------
    // Authority
    // -----------------------------------------------------------------------------------------------

    function test_RevertWhen_CallerLacksTheOperatorPolicyRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, nft.OPERATOR_POLICY_ROLE()
            )
        );
        vm.prank(alice);
        nft.setOperatorAllowlistEnforced(true);
    }

    /// @dev One role per authority: the key that mints cannot decide which marketplaces may settle.
    function test_MintAuthorityCannotChangeThePolicy() public {
        address minter = makeAddr("minter");
        vm.startPrank(admin);
        nft.grantRole(nft.MINT_ROLE(), minter);
        nft.revokeRole(nft.OPERATOR_POLICY_ROLE(), minter);
        vm.stopPrank();

        vm.prank(minter);
        nft.mint(bob, 44);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, minter, nft.OPERATOR_POLICY_ROLE()
            )
        );
        vm.prank(minter);
        nft.setOperatorAllowed(address(router), true);
    }

    function test_MintAndSeizeAreSeparateAuthorities() public {
        address minter = makeAddr("minter");
        address seizer = makeAddr("seizer");

        vm.startPrank(admin);
        nft.grantRole(nft.MINT_ROLE(), minter);
        nft.grantRole(nft.SEIZE_ROLE(), seizer);
        vm.stopPrank();

        vm.prank(minter);
        nft.mint(bob, 45);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, minter, nft.SEIZE_ROLE())
        );
        vm.prank(minter);
        nft.burn(45);

        vm.prank(seizer);
        nft.burn(45);
    }

    /// @dev `SEIZABLE` is not decorative: the issuer really can take a token from whoever holds it.
    function test_SeizeAuthorityBurnsATokenItDoesNotOwn() public {
        vm.prank(admin);
        nft.burn(TOKEN_ID);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, TOKEN_ID));
        nft.ownerOf(TOKEN_ID);
    }

    function test_RevertWhen_ZeroAddressIsGivenAStanding() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidOperator.selector, address(0)));
        vm.prank(admin);
        nft.setOperatorAllowed(address(0), true);
    }

    function test_RevertWhen_AdminIsTheZeroAddress() public {
        vm.expectRevert(ExtendedNFTBase.ExtendedNFTInvalidAdmin.selector);
        new ExtendedNFT("No Admin", "NOAD", address(0));
    }
}

contract SoulboundNFTTest is Test {
    SoulboundNFT internal nft;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant TOKEN_ID = 7;

    function setUp() public {
        nft = new SoulboundNFT("Soulbound", "SOUL", admin);
        vm.prank(admin);
        nft.mint(alice, TOKEN_ID);
    }

    function test_DeclaresItselfNonTransferable() public view {
        assertEq(
            nft.behaviorFlags(),
            BehaviorFlags.NON_TRANSFERABLE | BehaviorFlags.PAUSABLE | BehaviorFlags.BLOCKLIST
                | BehaviorFlags.METADATA_MUTABLE | BehaviorFlags.MINTABLE | BehaviorFlags.SEIZABLE
        );
    }

    function test_RevertWhen_TheOwnerTriesToTransfer() public {
        vm.expectRevert(ERC721NonTransferable.ERC721TransfersNotSupported.selector);
        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ID);
    }

    function test_RevertWhen_AnApprovedOperatorTriesToTransfer() public {
        address operator = makeAddr("operator");
        vm.prank(alice);
        nft.setApprovalForAll(operator, true);

        vm.expectRevert(ERC721NonTransferable.ERC721TransfersNotSupported.selector);
        vm.prank(operator);
        nft.transferFrom(alice, bob, TOKEN_ID);
    }

    /// @dev Soulbound here does not mean permanent, and `SEIZABLE` alongside the flag says so.
    function test_MintAndBurnStillWork() public {
        vm.startPrank(admin);
        nft.mint(bob, 8);
        assertEq(nft.ownerOf(8), bob);
        nft.burn(TOKEN_ID);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, TOKEN_ID));
        nft.ownerOf(TOKEN_ID);
    }

    /// @dev It never installed the operator module, so its configuration surface is not reachable at all.
    function test_ReportsOnlyTheExtensionItInstalled() public view {
        bytes4[] memory ids = nft.extensions();
        assertEq(ids.length, 3);
        assertEq(ids[0], ExtensionIds.NFT_NON_TRANSFERABLE);
        assertFalse(nft.hasExtension(ExtensionIds.NFT_OPERATOR_RESTRICTION));
        assertTrue(nft.hasExtension(ExtensionIds.NFT_TRANSFER_RESTRICTION));
    }
}
