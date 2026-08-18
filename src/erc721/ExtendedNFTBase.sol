// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC721ExtensionCore} from "./ERC721ExtensionCore.sol";

/**
 * @title ExtendedNFTBase
 * @notice The shared assembly behind the reference collections: roles, supply, and the authorisation
 *         dispatch every module's setters route into.
 *
 * @dev Carries no extension module of its own. The two reference collections install different ones and
 *      cannot install both — `NON_TRANSFERABLE` and `OPERATOR_RESTRICTED` are a forbidden combination,
 *      because a collection whose transfers always revert has no operator whose transfers could be
 *      screened, and declaring both would advertise a policy that can never apply.
 *
 *      ## Roles
 *
 *      `MINT_ROLE` and `SEIZE_ROLE` are split for the reason the fungible side splits them: `MINTABLE` and
 *      `SEIZABLE` are declared as two bits, and a vocabulary finer-grained than the authorities behind it
 *      is a vocabulary that misleads. `OPERATOR_POLICY_ROLE` is the third, and on a collection that
 *      enforces royalties it is the one that matters most to an outsider — it decides which marketplaces
 *      can settle a sale at all.
 *
 *      As on the fungible side, these are operational roles under a replaceable admin. `DEFAULT_ADMIN_ROLE`
 *      can grant itself any of them, so splitting the keys bounds one compromised operator and bounds
 *      nothing about the issuer.
 */
abstract contract ExtendedNFTBase is ERC721ExtensionCore, AccessControlUpgradeable {
    /// @notice Creates tokens. The power `BehaviorFlags.MINTABLE` declares.
    bytes32 public constant MINT_ROLE = keccak256("berc.role.MINT");

    /// @notice Destroys any account's token. The power `BehaviorFlags.SEIZABLE` declares.
    bytes32 public constant SEIZE_ROLE = keccak256("berc.role.SEIZE");

    /// @notice Decides which operators may move tokens they do not own, and whether that is enforced.
    bytes32 public constant OPERATOR_POLICY_ROLE = keccak256("berc.role.OPERATOR_POLICY");

    /// @notice Pauses transfers and freezes accounts.
    bytes32 public constant RESTRICTION_ROLE = keccak256("berc.role.RESTRICTION");

    /// @notice Rewrites token URIs, and can end that power permanently.
    bytes32 public constant METADATA_ROLE = keccak256("berc.role.METADATA");

    /// @notice The admin cannot be the zero address; the collection would have no reachable authority.
    error ExtendedNFTInvalidAdmin();

    function __ExtendedNFTBase_init(string memory name_, string memory symbol_, address admin)
        internal
        onlyInitializing
    {
        if (admin == address(0)) revert ExtendedNFTInvalidAdmin();

        __ERC721_init(name_, symbol_);
        __AccessControl_init();
        __ERC721ExtensionCore_init();

        // Declared by every collection on this base, whatever modules it installs, because {mint} and
        // {burn} are here and neither is optional. Leaving them out would let a collection with no
        // extensions report `behaviorFlags() == 0` — which the vocabulary defines as indistinguishable
        // from a plain ERC-721 — while its authorities could mint without limit and take any token.
        _declareBehavior(BehaviorFlags.MINTABLE | BehaviorFlags.SEIZABLE);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINT_ROLE, admin);
        _grantRole(SEIZE_ROLE, admin);
        _grantRole(OPERATOR_POLICY_ROLE, admin);
        _grantRole(RESTRICTION_ROLE, admin);
        _grantRole(METADATA_ROLE, admin);
    }

    /// @notice Creates `tokenId` and assigns it to `to`.
    function mint(address to, uint256 tokenId) external virtual onlyRole(MINT_ROLE) {
        _safeMint(to, tokenId);
    }

    /**
     * @notice Destroys `tokenId`, whoever holds it.
     * @dev Deliberately not restricted to the caller's own tokens, and deliberately {SEIZE_ROLE} rather
     *      than {MINT_ROLE}: a key that can only create tokens cannot reach anyone's holdings.
     */
    function burn(uint256 tokenId) external virtual onlyRole(SEIZE_ROLE) {
        _burn(tokenId);
    }

    /**
     * @inheritdoc ERC721ExtensionCore
     * @dev `super` rejects any extension this collection did not install, so the branches below only ever
     *      see IDs that are genuinely present.
     */
    function _authorizeExtensionConfig(bytes4 extensionId) internal view virtual override {
        super._authorizeExtensionConfig(extensionId);

        if (extensionId == ExtensionIds.NFT_OPERATOR_RESTRICTION) {
            _checkRole(OPERATOR_POLICY_ROLE);
        } else if (extensionId == ExtensionIds.NFT_TRANSFER_RESTRICTION) {
            _checkRole(RESTRICTION_ROLE);
        } else if (extensionId == ExtensionIds.NFT_MUTABLE_METADATA) {
            _checkRole(METADATA_ROLE);
        } else {
            revert ERC721ExtensionNotEnabled(extensionId);
        }
    }

    /// @dev Both parents declare it; ERC-721's answer and AccessControl's are both correct and both needed.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
