// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import {ERC721ExtensionCore} from "../erc721/ERC721ExtensionCore.sol";
import {ERC721MutableMetadata} from "../erc721/ERC721MutableMetadata.sol";
import {ERC721NonTransferable} from "../erc721/ERC721NonTransferable.sol";
import {ERC721OperatorRestriction} from "../erc721/ERC721OperatorRestriction.sol";
import {ERC721TransferRestriction} from "../erc721/ERC721TransferRestriction.sol";
import {ExtendedNFTBase} from "../erc721/ExtendedNFTBase.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";

/**
 * @title BERCNFTRuntimeV1
 * @notice One deployed contract that every canonical BERC collection clones. Deploy once per chain, then
 *         never again.
 *
 * @dev The non-fungible counterpart of {BERCRuntimeV1}, and the point at which the trust ladder becomes
 *      real for collections rather than merely available.
 *
 *      `BERCVerification` needed no changes to support this, which is the claim worth checking rather than
 *      asserting: it compares 45 bytes — a fixed prologue, an implementation address, a fixed epilogue —
 *      and has no opinion about what the implementation behind them is. A caller that pins this address
 *      verifies collections against it with the same library call that verifies fungible tokens against
 *      {BERCRuntimeV1}. The address is the only thing that differs, and the address is the thing being
 *      trusted.
 *
 *      ## Every module is inherited; registration decides which ones apply
 *
 *      A clone cannot add code, so the runtime carries all four modules and each token turns on the ones it
 *      asked for. That is what the `_...Active()` hooks on the modules exist for: overridden here against
 *      the registry, so a module the collection never installed costs it one `SLOAD` and changes nothing.
 *      A module that screened unconditionally would restrict every collection on the chain.
 *
 *      Nothing here is upgradeable and nothing has an owner. A second runtime is a second deployment at a
 *      second address, and every collection already pointing at this one keeps pointing at it forever.
 */
contract BERCNFTRuntimeV1 is
    ExtendedNFTBase,
    ERC721OperatorRestriction,
    ERC721TransferRestriction,
    ERC721MutableMetadata,
    ERC721NonTransferable
{
    /// @notice Human-readable identity. The address of this contract is the identity that actually matters.
    string public constant RUNTIME_NAME = "BERC NFT Runtime";

    /// @notice Bumped only by deploying a new runtime; this one will always answer 1.
    uint256 public constant RUNTIME_VERSION = 1;

    /// @notice An extension was requested that this runtime does not know how to install.
    error BERCNFTUnknownExtension(bytes4 extensionId);

    /**
     * @dev Locks the implementation's own storage. Without it this contract could be initialised directly,
     *      giving an address that passes no clone check but answers every BERC call — a decoy that looks
     *      canonical to anyone who verified by calling rather than by reading code.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialises one clone. Callable exactly once, and only on a clone.
     * @param extensionIds The extensions to install, from {ExtensionIds}. May be empty, which produces a
     *        collection whose transfers behave exactly like a plain ERC-721's. It is still not a plain
     *        ERC-721: like every collection on this runtime it declares `MINTABLE | SEIZABLE`, because
     *        `mint` and `burn` live on the shared base and no extension set removes them.
     * @param admin Receives every role. {BERCNFTFactoryV1} passes itself here, applies the initial
     *        configuration, and hands the roles on before the transaction ends.
     */
    function initialize(string calldata name_, string calldata symbol_, address admin, bytes4[] calldata extensionIds)
        external
        initializer
    {
        __ExtendedNFTBase_init(name_, symbol_, admin);

        for (uint256 i = 0; i < extensionIds.length; ++i) {
            _initializeExtension(extensionIds[i]);
        }

        // Fixes the extension set and rejects contradictory declarations, such as a collection asking to be
        // both soulbound and operator-screened. Must be last.
        _sealExtensions();
    }

    /**
     * @dev Duplicates are caught by `_registerExtension`, and anything this runtime does not recognise is
     *      caught here — so the set a caller asks for is exactly the set they get, or the deployment fails.
     */
    function _initializeExtension(bytes4 extensionId) private onlyInitializing {
        if (extensionId == ExtensionIds.NFT_OPERATOR_RESTRICTION) {
            __ERC721OperatorRestriction_init();
        } else if (extensionId == ExtensionIds.NFT_TRANSFER_RESTRICTION) {
            __ERC721TransferRestriction_init();
        } else if (extensionId == ExtensionIds.NFT_MUTABLE_METADATA) {
            __ERC721MutableMetadata_init();
        } else if (extensionId == ExtensionIds.NFT_NON_TRANSFERABLE) {
            __ERC721NonTransferable_init();
        } else {
            revert BERCNFTUnknownExtension(extensionId);
        }
    }

    // -----------------------------------------------------------------------------------------------
    // Per-collection module gating
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc ERC721OperatorRestriction
    function _operatorRestrictionActive() internal view virtual override returns (bool) {
        return hasExtension(ExtensionIds.NFT_OPERATOR_RESTRICTION);
    }

    /// @inheritdoc ERC721TransferRestriction
    function _transferRestrictionActive() internal view virtual override returns (bool) {
        return hasExtension(ExtensionIds.NFT_TRANSFER_RESTRICTION);
    }

    /// @inheritdoc ERC721NonTransferable
    function _nonTransferableActive() internal view virtual override returns (bool) {
        return hasExtension(ExtensionIds.NFT_NON_TRANSFERABLE);
    }

    // -----------------------------------------------------------------------------------------------
    // Linearisation plumbing
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc ERC721ExtensionCore
    function _checkTransferAllowed(address from, address to, uint256 tokenId, address auth)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ERC721OperatorRestriction, ERC721TransferRestriction, ERC721NonTransferable)
    {
        super._checkTransferAllowed(from, to, tokenId, auth);
    }

    /// @inheritdoc ERC721ExtensionCore
    function _extensionData(bytes4 extensionId)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ERC721OperatorRestriction, ERC721TransferRestriction, ERC721MutableMetadata)
        returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    /// @inheritdoc ERC721ExtensionCore
    function _authorizeExtensionConfig(bytes4 extensionId)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ExtendedNFTBase)
    {
        super._authorizeExtensionConfig(extensionId);
    }

    /// @inheritdoc ERC721MutableMetadata
    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override(ERC721Upgradeable, ERC721MutableMetadata)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    /// @inheritdoc ERC721MutableMetadata
    function _baseURI()
        internal
        view
        virtual
        override(ERC721Upgradeable, ERC721MutableMetadata)
        returns (string memory)
    {
        return super._baseURI();
    }

    /// @inheritdoc ExtendedNFTBase
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ExtendedNFTBase, ERC721Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
