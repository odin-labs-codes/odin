// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC20NonTransferable
 * @notice Marker interface for a token whose balances can only be created and destroyed, never moved.
 *
 * @dev There is nothing to configure and nothing to query beyond the extension's presence, so this carries
 *      only the error. It exists so that the revert reason is part of a published ABI rather than an
 *      implementation detail an integrator has to decode by hand.
 *
 *      `transfer` and `transferFrom` keep their signatures and always revert with
 *      {ERC20TransfersNotSupported}; `approve` still works and still emits `Approval`, because an allowance
 *      on a token that cannot move is harmless and removing it would break wallets that set one before
 *      transferring.
 *
 *      The error is deliberately *not* called `ERC20NonTransferable`. An error declared in an interface is
 *      in scope in every contract that inherits it, so an error sharing a name with the module contract
 *      would shadow it — and the first place that bites is an `override(...)` list, where the compiler
 *      quietly resolves the name to the error and then reports the contract as missing.
 */
interface IERC20NonTransferable {
    /// @notice This token cannot be transferred between accounts.
    error ERC20TransfersNotSupported();
}
