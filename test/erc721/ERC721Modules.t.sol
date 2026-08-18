// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ERC721MutableMetadata} from "../../src/erc721/ERC721MutableMetadata.sol";
import {ERC721TransferRestriction} from "../../src/erc721/ERC721TransferRestriction.sol";
import {ExtendedNFT, SoulboundNFT} from "../../src/erc721/ExtendedNFT.sol";
import {ExtensionIds} from "../../src/libraries/ExtensionIds.sol";

/**
 * @title ERC721RestrictionTest
 * @notice Pause and freeze on a collection, and the two asymmetries that keep them usable.
 */
contract ERC721RestrictionTest is Test {
    ExtendedNFT internal nft;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant TOKEN_ID = 1;

    function setUp() public {
        nft = new ExtendedNFT("Extended", "EXT", admin);
        vm.prank(admin);
        nft.mint(alice, TOKEN_ID);
    }

    function test_PauseStopsTransfers() public {
        vm.prank(admin);
        nft.setTransfersPaused(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721TransferRestriction.ERC721TransferRestricted.selector, nft.RESTRICTION_PAUSED()
            )
        );
        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ID);
    }

    /**
     * @dev A pause that also froze supply would brick the collection exactly when the authority most needs
     *      to act — which is the moment someone reaches for the pause.
     */
    function test_PauseDoesNotStopMintOrBurn() public {
        vm.startPrank(admin);
        nft.setTransfersPaused(true);
        nft.mint(bob, 2);
        nft.burn(2);
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), alice, "the existing token is untouched");
    }

    function test_FrozenSenderCannotTransfer() public {
        vm.prank(admin);
        nft.setFrozen(alice, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721TransferRestriction.ERC721TransferRestricted.selector, nft.RESTRICTION_SENDER_FROZEN()
            )
        );
        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ID);
    }

    function test_FrozenRecipientCannotReceive() public {
        vm.prank(admin);
        nft.setFrozen(bob, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721TransferRestriction.ERC721TransferRestricted.selector, nft.RESTRICTION_RECIPIENT_FROZEN()
            )
        );
        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ID);
    }

    /**
     * @dev Freezing is what an issuer does before seizing. If burning from a frozen account reverted, the
     *      freeze would have to be lifted first — which is precisely the window the freeze exists to close.
     */
    function test_BurnWorksOnAFrozenAccount() public {
        vm.startPrank(admin);
        nft.setFrozen(alice, true);
        nft.burn(TOKEN_ID);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, TOKEN_ID));
        nft.ownerOf(TOKEN_ID);
    }

    /// @dev Crediting an account nobody may transact with is a mistake with no upside.
    function test_MintToAFrozenAccountIsRejected() public {
        vm.startPrank(admin);
        nft.setFrozen(bob, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721TransferRestriction.ERC721TransferRestricted.selector, nft.RESTRICTION_RECIPIENT_FROZEN()
            )
        );
        nft.mint(bob, 2);
        vm.stopPrank();
    }

    /// @dev ERC-1404's screening call, so an integrator can ask before submitting rather than after.
    function test_DetectTransferRestrictionExplainsItself() public {
        assertEq(nft.detectTransferRestriction(alice, bob, TOKEN_ID), nft.RESTRICTION_OK());

        vm.prank(admin);
        nft.setTransfersPaused(true);
        assertEq(nft.detectTransferRestriction(alice, bob, TOKEN_ID), nft.RESTRICTION_PAUSED());
        assertEq(nft.messageForTransferRestriction(nft.RESTRICTION_PAUSED()), "Transfers are paused");

        vm.startPrank(admin);
        nft.setTransfersPaused(false);
        nft.setFrozen(alice, true);
        vm.stopPrank();
        assertEq(nft.detectTransferRestriction(alice, bob, TOKEN_ID), nft.RESTRICTION_SENDER_FROZEN());

        assertEq(nft.messageForTransferRestriction(nft.RESTRICTION_OK()), "Transfer allowed");
        assertEq(nft.messageForTransferRestriction(nft.RESTRICTION_SENDER_FROZEN()), "Sender account is frozen");
        assertEq(nft.messageForTransferRestriction(nft.RESTRICTION_RECIPIENT_FROZEN()), "Recipient account is frozen");
        assertEq(nft.messageForTransferRestriction(99), "Unknown restriction code");
    }

    /**
     * @dev A freeze names an account; the operator policy names a caller. They answer different questions,
     *      which is why they are two bits and not one.
     */
    function test_FreezeAndOperatorPolicyAreIndependent() public {
        address operator = makeAddr("operator");
        vm.prank(alice);
        nft.setApprovalForAll(operator, true);

        vm.startPrank(admin);
        nft.setOperatorAllowlistEnforced(true);
        nft.setOperatorAllowed(operator, true);
        nft.setFrozen(alice, true);
        vm.stopPrank();

        assertTrue(nft.isOperatorAllowed(operator), "the caller is permitted");

        // And the transfer still fails, because the account is not.
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721TransferRestriction.ERC721TransferRestricted.selector, nft.RESTRICTION_SENDER_FROZEN()
            )
        );
        vm.prank(operator);
        nft.transferFrom(alice, bob, TOKEN_ID);
    }

    function test_RevertWhen_ZeroAddressIsFrozen() public {
        vm.expectRevert(
            abi.encodeWithSelector(ERC721TransferRestriction.ERC721InvalidFreezeTarget.selector, address(0))
        );
        vm.prank(admin);
        nft.setFrozen(address(0), true);
    }

    function test_RevertWhen_CallerLacksTheRestrictionRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, nft.RESTRICTION_ROLE()
            )
        );
        vm.prank(alice);
        nft.setTransfersPaused(true);
    }

    /// @dev The two views an integrator screens with, which nothing else in this suite reads directly.
    function test_PauseAndFreezeAreReadableOnTheirOwn() public {
        assertFalse(nft.transfersPaused());
        assertFalse(nft.isFrozen(alice));

        vm.startPrank(admin);
        nft.setTransfersPaused(true);
        nft.setFrozen(alice, true);
        vm.stopPrank();

        assertTrue(nft.transfersPaused());
        assertTrue(nft.isFrozen(alice));
        assertFalse(nft.isFrozen(bob));
    }

    function test_ExtensionDataReportsThePause() public {
        assertEq(nft.extensionData(ExtensionIds.NFT_TRANSFER_RESTRICTION), abi.encode(false));

        vm.prank(admin);
        nft.setTransfersPaused(true);

        assertEq(nft.extensionData(ExtensionIds.NFT_TRANSFER_RESTRICTION), abi.encode(true));
    }

    /// @dev Soulbound and restriction is a permitted pair precisely because pause still governs minting.
    function test_RestrictionStillGovernsMintingOnASoulboundCollection() public {
        SoulboundNFT soulbound = new SoulboundNFT("Soulbound", "SOUL", admin);

        vm.startPrank(admin);
        soulbound.setFrozen(bob, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721TransferRestriction.ERC721TransferRestricted.selector, soulbound.RESTRICTION_RECIPIENT_FROZEN()
            )
        );
        soulbound.mint(bob, 1);
        vm.stopPrank();
    }
}

/**
 * @title ERC721MutableMetadataTest
 * @notice The risk that never touches the transfer path: the token does not move, and what it is changes.
 */
contract ERC721MutableMetadataTest is Test {
    ExtendedNFT internal nft;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");

    uint256 internal constant TOKEN_ID = 1;

    function setUp() public {
        nft = new ExtendedNFT("Extended", "EXT", admin);
        vm.prank(admin);
        nft.mint(alice, TOKEN_ID);
    }

    function test_BaseURIAppliesToEveryTokenWithoutOneOfItsOwn() public {
        vm.prank(admin);
        nft.setBaseURI("ipfs://collection/");

        assertEq(nft.baseURI(), "ipfs://collection/");
        assertEq(nft.tokenURI(TOKEN_ID), "ipfs://collection/1");
    }

    function test_PerTokenURIWinsOverTheBaseURI() public {
        vm.startPrank(admin);
        nft.setBaseURI("ipfs://collection/");
        nft.setTokenURI(TOKEN_ID, "ipfs://special");
        vm.stopPrank();

        assertEq(nft.tokenURI(TOKEN_ID), "ipfs://special");
    }

    function test_ClearingAPerTokenURIFallsBackToTheBaseURI() public {
        vm.startPrank(admin);
        nft.setBaseURI("ipfs://collection/");
        nft.setTokenURI(TOKEN_ID, "ipfs://special");
        nft.setTokenURI(TOKEN_ID, "");
        vm.stopPrank();

        assertEq(nft.tokenURI(TOKEN_ID), "ipfs://collection/1");
    }

    /// @dev The whole point of the flag: nothing moved, and the token means something else now.
    function test_MetadataCanBeRewrittenUnderAHolder() public {
        vm.prank(admin);
        nft.setTokenURI(TOKEN_ID, "ipfs://rare");
        assertEq(nft.tokenURI(TOKEN_ID), "ipfs://rare");

        vm.prank(admin);
        nft.setTokenURI(TOKEN_ID, "ipfs://common");

        assertEq(nft.ownerOf(TOKEN_ID), alice, "the holder never changed");
        assertEq(nft.tokenURI(TOKEN_ID), "ipfs://common", "and the token is worth something else");
    }

    /// @dev Delegating the unset case to OpenZeppelin keeps its existence check rather than returning "".
    function test_RevertWhen_AskingForANonexistentTokensURI() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(999)));
        nft.tokenURI(999);
    }

    function test_RevertWhen_APerTokenURIIsSetForANonexistentToken() public {
        vm.prank(admin);
        nft.setTokenURI(999, "ipfs://ghost");

        // Writing is not gated on existence — reading is, so the URI is unreachable until the token exists.
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(999)));
        nft.tokenURI(999);
    }

    // -----------------------------------------------------------------------------------------------
    // Freezing
    // -----------------------------------------------------------------------------------------------

    function test_FreezingEndsEveryWrite() public {
        vm.startPrank(admin);
        nft.setBaseURI("ipfs://collection/");
        nft.freezeMetadata();

        assertTrue(nft.metadataFrozen());

        vm.expectRevert(ERC721MutableMetadata.ERC721MetadataIsFrozen.selector);
        nft.setBaseURI("ipfs://replacement/");

        vm.expectRevert(ERC721MutableMetadata.ERC721MetadataIsFrozen.selector);
        nft.setTokenURI(TOKEN_ID, "ipfs://replacement");

        vm.expectRevert(ERC721MutableMetadata.ERC721MetadataIsFrozen.selector);
        nft.freezeMetadata();
        vm.stopPrank();

        assertEq(nft.tokenURI(TOKEN_ID), "ipfs://collection/1", "and what was there stays there");
    }

    /**
     * @dev The flag reports what the installed module can do, not what it is doing — the same rule every
     *      other extension follows. `metadataFrozen()` is where the current state lives, and because the
     *      freeze is one-way it is the one answer in this framework that never needs re-reading.
     */
    function test_FreezingDoesNotClearTheDeclaration() public {
        uint256 before = nft.behaviorFlags();

        vm.prank(admin);
        nft.freezeMetadata();

        assertEq(nft.behaviorFlags(), before, "declarations are fixed at deployment");
    }

    function test_ExtensionDataReportsTheFreezeAndTheBaseURI() public {
        vm.prank(admin);
        nft.setBaseURI("ipfs://collection/");
        assertEq(nft.extensionData(ExtensionIds.NFT_MUTABLE_METADATA), abi.encode(false, "ipfs://collection/"));

        vm.prank(admin);
        nft.freezeMetadata();
        assertEq(nft.extensionData(ExtensionIds.NFT_MUTABLE_METADATA), abi.encode(true, "ipfs://collection/"));
    }

    // -----------------------------------------------------------------------------------------------
    // Authority
    // -----------------------------------------------------------------------------------------------

    function test_RevertWhen_CallerLacksTheMetadataRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, nft.METADATA_ROLE()
            )
        );
        vm.prank(alice);
        nft.setBaseURI("ipfs://mine/");
    }

    /// @dev An unauthorised caller is told that, rather than being told about a freeze they cannot see.
    function test_AuthorityIsCheckedBeforeTheFreeze() public {
        vm.prank(admin);
        nft.freezeMetadata();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, nft.METADATA_ROLE()
            )
        );
        vm.prank(alice);
        nft.setBaseURI("ipfs://mine/");
    }

    function test_MetadataAuthorityCannotPauseOrMint() public {
        address curator = makeAddr("curator");
        vm.startPrank(admin);
        nft.grantRole(nft.METADATA_ROLE(), curator);
        vm.stopPrank();

        vm.prank(curator);
        nft.setBaseURI("ipfs://curated/");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, curator, nft.RESTRICTION_ROLE()
            )
        );
        vm.prank(curator);
        nft.setTransfersPaused(true);
    }
}
