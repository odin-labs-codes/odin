// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20NonTransferable} from "../interfaces/IERC20NonTransferable.sol";
import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC20ExtensionCore} from "./ERC20ExtensionCore.sol";

/**
 * @title ERC20NonTransferable
 * @notice Balances can be minted and burned but never moved between accounts.
 *
 * @dev Implemented as a phase-1 check rather than by overriding `transfer` and `transferFrom`, so that
 *      every path that could move value — including {ERC20TransferFee-transferExactOut} and anything a
 *      future module adds — is closed by the same three lines. Overriding the two public entry points would
 *      leave `_transfer` reachable from inside the contract and would have to be revisited every time a new
 *      module introduces a transfer path.
 *
 *      Holds no storage: there is nothing to configure. A token either can be transferred or cannot, and
 *      making that switchable would turn `NON_TRANSFERABLE` into a claim an integrator could not rely on.
 */
abstract contract ERC20NonTransferable is ERC20ExtensionCore, IERC20NonTransferable {
    function __ERC20NonTransferable_init() internal onlyInitializing {
        _registerExtension(ExtensionIds.NON_TRANSFERABLE, BehaviorFlags.NON_TRANSFERABLE);
    }

    /// @inheritdoc ERC20ExtensionCore
    function _checkTransferAllowed(address from, address to, uint256 value) internal view virtual override {
        if (from != address(0) && to != address(0)) {
            revert ERC20TransfersNotSupported();
        }
        super._checkTransferAllowed(from, to, value);
    }
}
