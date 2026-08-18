// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import {ERC721ExtensionCore} from "./ERC721ExtensionCore.sol";
import {ERC721MutableMetadata} from "./ERC721MutableMetadata.sol";
import {ERC721NonTransferable} from "./ERC721NonTransferable.sol";
import {ERC721OperatorRestriction} from "./ERC721OperatorRestriction.sol";
import {ERC721TransferRestriction} from "./ERC721TransferRestriction.sol";
import {ExtendedNFTBase} from "./ExtendedNFTBase.sol";

/**
 * @title ExtendedNFT
 * @notice The reference collection: a plain ERC-721 to anyone who has never heard of this framework, and a
 *         collection that tells you in advance whether your marketplace can settle a sale to anyone who has.
 *
 * @dev Deployed directly, with no proxy. The extension set, the behaviour word and the code are all fixed
 *      at deployment; `behaviorFlags()` does not set `UPGRADEABLE`, and that is structural rather than a
 *      promise — there is no upgrade function, no admin slot, and `_disableInitializers()` runs at the end
 *      of the constructor so the initialisation path can never be re-entered.
 *
 *      It declares `OPERATOR_RESTRICTED | PAUSABLE | BLOCKLIST | METADATA_MUTABLE | MINTABLE | SEIZABLE`.
 *      Two of those are worth the call on their own:
 *
 *      - `OPERATOR_RESTRICTED`, because an operator policy is invisible to a marketplace that simulates the
 *        owner's own transfer, shows up only when settlement reverts, and looks like a marketplace bug.
 *      - `METADATA_MUTABLE`, because it is the risk that never touches the transfer path at all — the token
 *        does not move, and what it is worth changes.
 */
contract ExtendedNFT is ExtendedNFTBase, ERC721OperatorRestriction, ERC721TransferRestriction, ERC721MutableMetadata {
    /**
     * @param name_ ERC-721 name. Unchanged in meaning; wallets read it exactly as they always have.
     * @param symbol_ ERC-721 symbol.
     * @param admin Receives every role. Expected to redistribute them across separate authorities.
     */
    constructor(string memory name_, string memory symbol_, address admin) {
        _initializeExtendedNFT(name_, symbol_, admin);
        _disableInitializers();
    }

    /**
     * @dev The module initialisers are `onlyInitializing`, which needs an `initializer` frame around them.
     *      OZ v5's `initializer` explicitly supports running inside a constructor.
     */
    function _initializeExtendedNFT(string memory name_, string memory symbol_, address admin) private initializer {
        __ExtendedNFTBase_init(name_, symbol_, admin);
        __ERC721OperatorRestriction_init();
        __ERC721TransferRestriction_init();
        __ERC721MutableMetadata_init();
        // Fixes the extension set and rejects contradictory declarations. Must be last.
        _sealExtensions();
    }

    // -----------------------------------------------------------------------------------------------
    // Linearisation plumbing
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc ERC721ExtensionCore
    function _checkTransferAllowed(address from, address to, uint256 tokenId, address auth)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ERC721OperatorRestriction, ERC721TransferRestriction)
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

/**
 * @title SoulboundNFT
 * @notice The other reference collection: tokens can be minted to an account and burned from it, and can
 *         never move between accounts.
 *
 * @dev Declares `NON_TRANSFERABLE | PAUSABLE | BLOCKLIST | METADATA_MUTABLE | MINTABLE | SEIZABLE`, and is
 *      a separate contract from {ExtendedNFT} rather than a configuration of it because their two headline
 *      declarations contradict: a collection whose transfer path is unreachable has no operator transfer to
 *      screen. {BehaviorFlags-conflictingPair} rejects the pair, so an assembly that tried to install both
 *      would fail in its own constructor rather than deploy something misleading.
 *
 *      The restriction module is *not* dead weight here, which is why that pair is allowed: pause and
 *      freeze still govern minting, and minting to a frozen account stays rejected.
 *
 *      Note what an integrator gets from the flag word. `NON_TRANSFERABLE` is not a promise made in a
 *      README, it is a bit read from the collection — and `MINTABLE | SEIZABLE` alongside it says plainly
 *      that soulbound here does not mean permanent, because the issuer can still take the token back.
 */
contract SoulboundNFT is ExtendedNFTBase, ERC721NonTransferable, ERC721TransferRestriction, ERC721MutableMetadata {
    constructor(string memory name_, string memory symbol_, address admin) {
        _initializeSoulboundNFT(name_, symbol_, admin);
        _disableInitializers();
    }

    function _initializeSoulboundNFT(string memory name_, string memory symbol_, address admin) private initializer {
        __ExtendedNFTBase_init(name_, symbol_, admin);
        __ERC721NonTransferable_init();
        __ERC721TransferRestriction_init();
        __ERC721MutableMetadata_init();
        _sealExtensions();
    }

    // -----------------------------------------------------------------------------------------------
    // Linearisation plumbing
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc ERC721ExtensionCore
    function _checkTransferAllowed(address from, address to, uint256 tokenId, address auth)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ERC721NonTransferable, ERC721TransferRestriction)
    {
        super._checkTransferAllowed(from, to, tokenId, auth);
    }

    /// @inheritdoc ERC721ExtensionCore
    function _extensionData(bytes4 extensionId)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ERC721TransferRestriction, ERC721MutableMetadata)
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
