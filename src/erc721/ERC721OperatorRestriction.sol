// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721OperatorRestriction} from "../interfaces/IERC721OperatorRestriction.sol";
import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC721ExtensionCore} from "./ERC721ExtensionCore.sol";

/**
 * @title ERC721OperatorRestriction
 * @notice Transfers made by someone other than the owner can be screened against an allowlist, and the
 *         allowlist is readable before anyone relies on it.
 *
 * @dev The module the fungible half has no counterpart to, and the reason porting was worth doing.
 *
 *      ## The owner is never screened
 *
 *      A policy that could stop an owner moving their own token is a soulbound token with extra steps, and
 *      the framework already has a flag that says so honestly. This screens the *operator*: the case where
 *      `auth` is neither the zero address nor the current owner, which `ERC721._update` distinguishes for
 *      free and `ERC20._update` cannot distinguish at all.
 *
 *      Mint and burn arrive with `auth == address(0)` and are never screened. An allowlist that could
 *      block minting would be a pause, which is again a different flag.
 *
 *      ## Why the policy has an off switch rather than an empty list
 *
 *      An allowlist that starts empty and is enforced from birth is a collection that cannot be sold until
 *      someone remembers to populate it, and the failure looks identical to a bug. So enforcement is a
 *      separate boolean, off at deployment, and {isOperatorAllowed} answers `true` for everyone while it
 *      is off. A caller reads one function and never has to ask which mode the collection is in.
 *
 *      The flag, though, is declared as soon as the module is *installed*, following the same rule as
 *      every other extension: the authority can switch enforcement on at any moment, so a collection that
 *      carries this module is a collection whose transfers can start being refused, and an integrator who
 *      cached `false` would be wrong exactly when it mattered.
 *
 * @custom:storage-location erc7201:berc.storage.ERC721OperatorRestriction
 */
abstract contract ERC721OperatorRestriction is ERC721ExtensionCore, IERC721OperatorRestriction {
    /// @custom:storage-location erc7201:berc.storage.ERC721OperatorRestriction
    struct OperatorRestrictionStorage {
        bool enforced;
        mapping(address operator => bool) allowed;
    }

    // keccak256(abi.encode(uint256(keccak256("berc.storage.ERC721OperatorRestriction")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OPERATOR_RESTRICTION_STORAGE =
        0x8c3d5a06da615ae5a57c4cd20225724247eff71ed22fad8f4d3c8ab335a9b100;

    function _getOperatorRestrictionStorage() private pure returns (OperatorRestrictionStorage storage $) {
        assembly ("memory-safe") {
            $.slot := OPERATOR_RESTRICTION_STORAGE
        }
    }

    function __ERC721OperatorRestriction_init() internal onlyInitializing {
        _registerExtension(ExtensionIds.NFT_OPERATOR_RESTRICTION, BehaviorFlags.OPERATOR_RESTRICTED);
    }

    // -----------------------------------------------------------------------------------------------
    // Transfer pipeline
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc ERC721ExtensionCore
    function _checkTransferAllowed(address from, address to, uint256 tokenId, address auth)
        internal
        view
        virtual
        override
    {
        // `auth == address(0)` is a mint, a burn or an internal transfer; `auth == from` is the owner
        // moving their own token. Neither is an operator, and neither is what this module screens.
        if (_operatorRestrictionActive() && auth != address(0) && auth != from) {
            if (!isOperatorAllowed(auth)) revert ERC721OperatorNotAllowed(auth);
        }
        super._checkTransferAllowed(from, to, tokenId, auth);
    }

    // -----------------------------------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------------------------------

    /**
     * @notice Turns enforcement on or off without disturbing the allowlist itself.
     * @dev Separating the switch from the set means a collection can prepare its allowlist over several
     *      transactions and then start enforcing in one, instead of enforcing an incomplete list in the
     *      window between the first entry and the last.
     */
    function setOperatorAllowlistEnforced(bool enforced) external virtual {
        _authorizeExtensionConfig(ExtensionIds.NFT_OPERATOR_RESTRICTION);

        _getOperatorRestrictionStorage().enforced = enforced;

        emit OperatorAllowlistEnforced(enforced);
        _emitExtensionConfigured(ExtensionIds.NFT_OPERATOR_RESTRICTION);
    }

    /**
     * @notice Adds or removes one operator from the allowlist.
     * @dev The zero address is rejected rather than stored. It is how mint and burn identify themselves in
     *      the pipeline, so a standing recorded for it could never be consulted, and letting it be written
     *      would leave a value in storage that reads back meaningfully and means nothing.
     */
    function setOperatorAllowed(address operator, bool allowed) external virtual {
        _authorizeExtensionConfig(ExtensionIds.NFT_OPERATOR_RESTRICTION);
        if (operator == address(0)) revert ERC721InvalidOperator(operator);

        _getOperatorRestrictionStorage().allowed[operator] = allowed;

        emit OperatorAllowed(operator, allowed);
        _emitExtensionConfigured(ExtensionIds.NFT_OPERATOR_RESTRICTION);
    }

    // -----------------------------------------------------------------------------------------------
    // Discovery
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC721OperatorRestriction
    function isOperatorAllowed(address operator) public view virtual returns (bool) {
        OperatorRestrictionStorage storage $ = _getOperatorRestrictionStorage();
        return !$.enforced || $.allowed[operator];
    }

    /// @inheritdoc IERC721OperatorRestriction
    function operatorAllowlistEnforced() public view virtual returns (bool) {
        return _getOperatorRestrictionStorage().enforced;
    }

    /**
     * @inheritdoc ERC721ExtensionCore
     * @dev Reports whether the allowlist is being consulted. The membership of the list is not enumerable
     *      on chain and this does not pretend otherwise — {isOperatorAllowed} answers per address, and the
     *      full set is reconstructed from {OperatorAllowed} logs.
     *
     *      The delegation on the last line is what keeps this module from being the end of the chain: an
     *      assembly that installs it alongside others has to be able to ask any of them for their data, and
     *      whichever module happens to sit last would otherwise swallow every id but its own.
     */
    function _extensionData(bytes4 extensionId) internal view virtual override returns (bytes memory) {
        if (extensionId == ExtensionIds.NFT_OPERATOR_RESTRICTION) {
            return abi.encode(operatorAllowlistEnforced());
        }
        return super._extensionData(extensionId);
    }

    /**
     * @dev Whether this module's check applies. Always true for an assembly that inherits the module
     *      because it wants the behaviour — Solidity resolves the call statically there, so the gate costs
     *      such a collection nothing.
     *
     *      It exists for the opposite construction: a shared runtime that inherits every module and turns
     *      each one on per collection. A module that screened unconditionally would restrict every token
     *      that never asked for it.
     */
    function _operatorRestrictionActive() internal view virtual returns (bool) {
        return true;
    }
}
