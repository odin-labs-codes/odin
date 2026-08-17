// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import {IERC721Behavior} from "../interfaces/IERC721Behavior.sol";
import {IERC721Extensions} from "../interfaces/IERC721Extensions.sol";
import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";

/**
 * @title ERC721ExtensionCore
 * @notice The registry every non-fungible extension module registers with, and the one place transfer
 *         phase order is decided.
 *
 * @dev The counterpart of {ERC20ExtensionCore}, and a deliberate copy rather than a shared base. The two
 *      registries are the same idea; the two pipelines are not, and it is the pipeline this contract
 *      exists to own.
 *
 *      ## Why this is not the fungible core with a different parent
 *
 *      Making {ERC20ExtensionCore} generic over the token type was the obvious move and is the wrong one.
 *      The phases genuinely differ: there is no fee phase here and cannot be, because withholding 2.5% of
 *      token #42 is not a thing that exists, and `ERC721._update` takes an argument the fungible one does
 *      not — the address that authorised the transfer. A shared base would have been shared in name and
 *      forked in substance, while re-opening a pipeline that has been through four rounds of review.
 *
 *      What *is* shared is the part with no inheritance in it: {BehaviorFlags}, {ExtensionIds} and
 *      `BERCVerification`. An integrator holds one copy of the vocabulary and reads one word, whichever
 *      token standard the address in front of them turns out to implement.
 *
 *      ## Why `_update` is overridden here and nowhere else
 *
 *      Same reason as the fungible core. If every module overrode `_update` and called `super`, execution
 *      order would fall out of C3 linearisation, and an assembly listing its modules in one order would
 *      behave differently from the same modules listed in another. Here modules override *phases*, and the
 *      order below is the order regardless of inheritance sequence.
 *
 *      One phase exists today because one phase has a consumer today. A module that needs to act after
 *      balances settle — a hook being the obvious candidate — gets its phase added to {_update} below, in
 *      the open, rather than by inserting itself into a chain.
 *
 * @custom:storage-location erc7201:berc.storage.ERC721ExtensionRegistry
 */
abstract contract ERC721ExtensionCore is Initializable, ERC721Upgradeable, IERC721Extensions, IERC721Behavior {
    /// @custom:storage-location erc7201:berc.storage.ERC721ExtensionRegistry
    struct ExtensionRegistryStorage {
        bytes4[] ids;
        mapping(bytes4 id => bool) enabled;
        uint256 behaviorFlags;
        bool isSealed;
    }

    // keccak256(abi.encode(uint256(keccak256("berc.storage.ERC721ExtensionRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC721_EXTENSION_REGISTRY_STORAGE =
        0x46ee24d3bd65b7c31a5e819c0a829e2351fee3cc279815d12504d1bfb433e500;

    /// @notice The same extension was registered twice.
    error ERC721ExtensionAlreadyRegistered(bytes4 extensionId);

    /// @notice The extension set was already sealed; registration is only possible during construction.
    error ERC721ExtensionSetSealed();

    /// @notice The discovery surface was read before the assembly called `_sealExtensions()`.
    error ERC721ExtensionSetNotSealed();

    /// @notice A configuration call named an extension this collection did not install.
    error ERC721ExtensionNotEnabled(bytes4 extensionId);

    /// @notice The declared behaviours contradict each other. See `BehaviorFlags.conflictingPair`.
    error ERC721IncompatibleBehaviors(uint256 first, uint256 second);

    /// @notice A behaviour bit outside `BehaviorFlags.ALL` was declared.
    error ERC721UnknownBehaviorFlag(uint256 flags);

    function _getExtensionRegistryStorage() private pure returns (ExtensionRegistryStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ERC721_EXTENSION_REGISTRY_STORAGE
        }
    }

    function __ERC721ExtensionCore_init() internal onlyInitializing {}

    // -----------------------------------------------------------------------------------------------
    // Transfer pipeline
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev The only `_update` override in the non-fungible half of the framework.
     *
     *      `from` is read before delegating rather than taken from `super`'s return value, because a phase
     *      that rejects a transfer has to run before the transfer happens — the same ordering rule the
     *      fungible pipeline follows, and the one that keeps a future after-phase honest. It costs one warm
     *      `SLOAD` over reading the previous owner on the way out.
     *
     *      `auth` is passed through untouched. It is `address(0)` for mint, burn and internal transfers,
     *      and the caller's address for a public `transferFrom` — exactly the distinction an operator
     *      policy needs, and information `ERC20._update` never receives.
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);

        // Phase 1. Reject the transfer, or return and let it proceed.
        _checkTransferAllowed(from, to, tokenId, auth);

        return super._update(to, tokenId, auth);
    }

    /**
     * @dev Phase 1. Revert to reject the transfer. Called for mint and burn too, with the zero address
     *      intact on whichever side, so a module can apply different rules to supply changes than it does
     *      to transfers. Modules must call `super._checkTransferAllowed` so several can coexist.
     *
     *      `auth` is who asked. `address(0)` means nobody external did: a mint, a burn, or a transfer the
     *      collection made on its own behalf.
     */
    function _checkTransferAllowed(address from, address to, uint256 tokenId, address auth) internal view virtual {}

    // -----------------------------------------------------------------------------------------------
    // Registration
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev Installs one module and declares the behaviour it brings. Constructor-time only: the set an
     *      integrator reads is the set the collection was deployed with, forever.
     */
    function _registerExtension(bytes4 extensionId, uint256 flags) internal onlyInitializing {
        ExtensionRegistryStorage storage $ = _getExtensionRegistryStorage();
        if ($.isSealed) revert ERC721ExtensionSetSealed();
        if ($.enabled[extensionId]) revert ERC721ExtensionAlreadyRegistered(extensionId);

        $.enabled[extensionId] = true;
        $.ids.push(extensionId);
        _declareBehavior(flags);
    }

    /**
     * @dev Declares behaviour not tied to an extension module — `MINTABLE` and `SEIZABLE`, which come from
     *      the assembly rather than from anything it inherits.
     */
    function _declareBehavior(uint256 flags) internal onlyInitializing {
        if (flags & ~BehaviorFlags.ALL != 0) revert ERC721UnknownBehaviorFlag(flags);
        ExtensionRegistryStorage storage $ = _getExtensionRegistryStorage();
        if ($.isSealed) revert ERC721ExtensionSetSealed();
        $.behaviorFlags |= flags;
    }

    /**
     * @notice Freezes the extension set and validates that the declared behaviours are consistent.
     * @dev **Every assembly must call this as the last step of its constructor or initialiser.** Until it
     *      does, {extensions}, {hasExtension}, {extensionData} and {behaviorFlags} all revert, so an
     *      assembly that forgets has no discovery surface rather than a quietly unvalidated one.
     */
    function _sealExtensions() internal onlyInitializing {
        ExtensionRegistryStorage storage $ = _getExtensionRegistryStorage();
        if ($.isSealed) revert ERC721ExtensionSetSealed();

        (uint256 first, uint256 second) = BehaviorFlags.conflictingPair($.behaviorFlags);
        if (first != 0) revert ERC721IncompatibleBehaviors(first, second);

        $.isSealed = true;
    }

    /// @dev Emits {ExtensionConfigured} carrying the extension's full configuration after the change.
    function _emitExtensionConfigured(bytes4 extensionId) internal {
        emit ExtensionConfigured(extensionId, extensionData(extensionId));
    }

    /**
     * @dev Every configuration entry point routes through here with its own extension ID, so an assembly
     *      states its authorisation policy once and no module has to know what that policy is.
     *
     *      Rejecting an ID the collection never installed belongs here rather than in each module: it is
     *      what keeps a setter on an uninstalled module from writing storage nothing reads.
     */
    function _authorizeExtensionConfig(bytes4 extensionId) internal view virtual {
        if (!hasExtension(extensionId)) revert ERC721ExtensionNotEnabled(extensionId);
    }

    // -----------------------------------------------------------------------------------------------
    // Discovery
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC721Extensions
    function extensions() public view virtual returns (bytes4[] memory) {
        return _sealedStorage().ids;
    }

    /// @inheritdoc IERC721Extensions
    function hasExtension(bytes4 extensionId) public view virtual returns (bool) {
        return _sealedStorage().enabled[extensionId];
    }

    /**
     * @inheritdoc IERC721Extensions
     * @dev Deliberately not `virtual`. The seal check and the not-installed check belong to every call, and
     *      a module overriding the public function would answer for its own ID before either one ran.
     *      Modules extend {_extensionData}, which this reaches only once both have passed.
     */
    function extensionData(bytes4 extensionId) public view returns (bytes memory) {
        if (!_sealedStorage().enabled[extensionId]) revert ERC721ExtensionNotEnabled(extensionId);
        return _extensionData(extensionId);
    }

    /**
     * @dev Modules override this to return their own configuration and delegate everything else upward.
     *      Reaching the base case means the ID belongs to an installed module with nothing to report, so
     *      empty bytes is the right answer — "installed but unconfigured" stays distinguishable from
     *      "not installed", which reverts one level up.
     */
    function _extensionData(bytes4) internal view virtual returns (bytes memory) {
        return "";
    }

    /// @inheritdoc IERC721Behavior
    function behaviorFlags() public view virtual returns (uint256) {
        return _sealedStorage().behaviorFlags;
    }

    function _sealedStorage() private view returns (ExtensionRegistryStorage storage $) {
        $ = _getExtensionRegistryStorage();
        if (!$.isSealed) revert ERC721ExtensionSetNotSealed();
    }
}
