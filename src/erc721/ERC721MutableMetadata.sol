// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC721ExtensionCore} from "./ERC721ExtensionCore.sol";

/**
 * @title ERC721MutableMetadata
 * @notice A `tokenURI` the metadata authority can rewrite after mint — and a one-way switch that ends it.
 *
 * @dev The declaration this module exists for is `METADATA_MUTABLE`, and it is the non-fungible half's
 *      quietest risk. Every other flag describes something that happens when value moves. This one
 *      describes something that happens while nothing moves at all: the token stays in the same wallet with
 *      the same id, and what it *is* changes.
 *
 *      That matters to anyone pricing a token rather than merely holding it. A lending protocol taking an
 *      NFT as collateral values it by its traits; an index weights a collection by them. Both are exposed
 *      to an authority that can rewrite the traits underneath them, and neither can discover it by
 *      simulating anything, because there is nothing to simulate.
 *
 *      ## Freezing does not clear the flag
 *
 *      {freezeMetadata} is permanent and there is deliberately no way back, which is what makes it worth
 *      anything: a collection that can un-freeze has promised nothing. But the flag stays set, following
 *      the rule the whole vocabulary follows — a flag reports what the *installed module can do*, not what
 *      it is doing now. An integrator reads {metadataFrozen} for the current state, and because the freeze
 *      is one-way, `true` is the one answer here that never needs re-reading.
 *
 *      ## Resolution order
 *
 *      A per-token URI wins if one is set; otherwise the base URI is concatenated with the token id, which
 *      is what almost every collection actually wants. Both are writable, so both are covered by the flag
 *      and both are stopped by the freeze.
 *
 * @custom:storage-location erc7201:berc.storage.ERC721MutableMetadata
 */
abstract contract ERC721MutableMetadata is ERC721ExtensionCore {
    using Strings for uint256;

    /// @notice The collection's metadata was frozen permanently.
    event MetadataFrozen();

    /// @notice One token's URI was set or cleared.
    event TokenURIUpdated(uint256 indexed tokenId, string uri);

    /// @notice The base URI was replaced.
    event BaseURIUpdated(string baseURI);

    /// @notice The metadata is frozen; no further writes are possible, by anyone, ever.
    error ERC721MetadataIsFrozen();

    /// @custom:storage-location erc7201:berc.storage.ERC721MutableMetadata
    struct MutableMetadataStorage {
        bool frozen;
        string baseURI;
        mapping(uint256 tokenId => string uri) tokenURIs;
    }

    // keccak256(abi.encode(uint256(keccak256("berc.storage.ERC721MutableMetadata")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC721_MUTABLE_METADATA_STORAGE =
        0x154b40b40fb2cac4981d9efd398e167f3f79000ff9d9adcbd5e88f8092137700;

    function _getMutableMetadataStorage() private pure returns (MutableMetadataStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ERC721_MUTABLE_METADATA_STORAGE
        }
    }

    function __ERC721MutableMetadata_init() internal onlyInitializing {
        _registerExtension(ExtensionIds.NFT_MUTABLE_METADATA, BehaviorFlags.METADATA_MUTABLE);
    }

    // -----------------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------------

    /**
     * @notice Whether the metadata can still be rewritten. Once `true`, permanently `true`.
     * @dev The one view in this framework whose answer an integrator never has to re-read, because the
     *      only transition is in the direction that removes a risk.
     */
    function metadataFrozen() public view virtual returns (bool) {
        return _getMutableMetadataStorage().frozen;
    }

    /// @notice The prefix used for tokens with no URI of their own.
    function baseURI() public view virtual returns (string memory) {
        return _getMutableMetadataStorage().baseURI;
    }

    /// @inheritdoc ERC721ExtensionCore
    function _extensionData(bytes4 extensionId) internal view virtual override returns (bytes memory) {
        if (extensionId == ExtensionIds.NFT_MUTABLE_METADATA) {
            MutableMetadataStorage storage $ = _getMutableMetadataStorage();
            return abi.encode($.frozen, $.baseURI);
        }
        return super._extensionData(extensionId);
    }

    /// @dev Feeds OpenZeppelin's default `tokenURI`, which concatenates this with the token id.
    function _baseURI() internal view virtual override returns (string memory) {
        return _getMutableMetadataStorage().baseURI;
    }

    /**
     * @inheritdoc ERC721Upgradeable
     * @dev A per-token URI wins over the base URI. Delegating to `super` for the unset case keeps
     *      OpenZeppelin's existence check — asking for a token that was never minted still reverts with
     *      `ERC721NonexistentToken` rather than returning an empty string.
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        string memory uri = _getMutableMetadataStorage().tokenURIs[tokenId];
        if (bytes(uri).length > 0) {
            _requireOwned(tokenId);
            return uri;
        }
        return super.tokenURI(tokenId);
    }

    // -----------------------------------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------------------------------

    /// @notice Sets or clears one token's URI. Pass an empty string to fall back to the base URI.
    function setTokenURI(uint256 tokenId, string calldata uri) external virtual {
        _authorizeMetadataWrite();

        _getMutableMetadataStorage().tokenURIs[tokenId] = uri;

        emit TokenURIUpdated(tokenId, uri);
        _emitExtensionConfigured(ExtensionIds.NFT_MUTABLE_METADATA);
    }

    /// @notice Replaces the prefix used by every token with no URI of its own.
    function setBaseURI(string calldata newBaseURI) external virtual {
        _authorizeMetadataWrite();

        _getMutableMetadataStorage().baseURI = newBaseURI;

        emit BaseURIUpdated(newBaseURI);
        _emitExtensionConfigured(ExtensionIds.NFT_MUTABLE_METADATA);
    }

    /**
     * @notice Ends metadata writes permanently.
     * @dev There is no counterpart. A freeze that could be lifted would be a setting rather than a
     *      guarantee, and an integrator reading {metadataFrozen} would learn nothing they could rely on.
     */
    function freezeMetadata() external virtual {
        _authorizeMetadataWrite();

        _getMutableMetadataStorage().frozen = true;

        emit MetadataFrozen();
        _emitExtensionConfigured(ExtensionIds.NFT_MUTABLE_METADATA);
    }

    /// @dev Authority first, then the freeze — so an unauthorised caller is told that, not about a freeze.
    function _authorizeMetadataWrite() private view {
        _authorizeExtensionConfig(ExtensionIds.NFT_MUTABLE_METADATA);
        if (_getMutableMetadataStorage().frozen) revert ERC721MetadataIsFrozen();
    }
}
