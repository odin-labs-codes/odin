// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC721ExtensionCore} from "./ERC721ExtensionCore.sol";

/**
 * @title ERC721NonTransferable
 * @notice Tokens can be minted and burned but never moved between accounts. Soulbound.
 *
 * @dev Implemented as a phase-1 check rather than by overriding `transferFrom` and `safeTransferFrom`, so
 *      that every path that could move a token is closed by the same three lines. Overriding the public
 *      entry points would leave `_transfer` reachable from inside the contract and would have to be
 *      revisited every time a module introduced a new way to move one.
 *
 *      Holds no storage: there is nothing to configure. A collection either can be transferred or cannot,
 *      and making that switchable would turn `NON_TRANSFERABLE` into a claim an integrator could not rely
 *      on — which is the whole value of the flag.
 */
abstract contract ERC721NonTransferable is ERC721ExtensionCore {
    /// @notice This collection is soulbound; only mint and burn move tokens.
    error ERC721TransfersNotSupported();

    function __ERC721NonTransferable_init() internal onlyInitializing {
        _registerExtension(ExtensionIds.NFT_NON_TRANSFERABLE, BehaviorFlags.NON_TRANSFERABLE);
    }

    /// @inheritdoc ERC721ExtensionCore
    function _checkTransferAllowed(address from, address to, uint256 tokenId, address auth)
        internal
        view
        virtual
        override
    {
        if (_nonTransferableActive() && from != address(0) && to != address(0)) {
            revert ERC721TransfersNotSupported();
        }
        super._checkTransferAllowed(from, to, tokenId, auth);
    }

    /**
     * @dev Whether this module's check applies. See the note on
     *      {ERC721OperatorRestriction-_operatorRestrictionActive}; the reasoning is identical.
     */
    function _nonTransferableActive() internal view virtual returns (bool) {
        return true;
    }
}
