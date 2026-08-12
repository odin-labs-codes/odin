// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC20TransferHook
 * @notice Discovery surface for a token that calls out to a policy contract on every transfer.
 *
 * @dev A transfer hook is the heaviest thing a token can do to an integrator: it turns `transfer` from an
 *      operation with known cost and known failure modes into a call whose gas and revert behaviour are
 *      controlled by a third party. This extension does not try to make that cheap. It makes it *stated*:
 *
 *      - {transferHook} names the contract that will be called, so it can be inspected before integrating.
 *      - {transferHookGasLimit} bounds the gas it may burn, so a caller can budget a worst case.
 *      - `TRANSFER_HOOK` in `behaviorFlags()` warns that transfers may revert for reasons that have nothing
 *        to do with balances or allowances.
 *
 *      The hook runs *after* balances have settled and inside a reentrancy guard, and a revert inside it
 *      reverts the transfer. See `ERC20TransferHook` for the exact ordering guarantees.
 *
 *      Extension data encoding for {IERC20Extensions-extensionData}:
 *      `abi.encode(address hook, uint32 gasLimit)`.
 */
interface IERC20TransferHook {
    /// @notice The requested gas limit is outside the range this token accepts.
    error ERC20InvalidHookGasLimit(uint32 gasLimit, uint32 minGasLimit, uint32 maxGasLimit);

    /// @notice A hook must be a contract; an EOA would silently accept every transfer.
    error ERC20InvalidTransferHook(address hook);

    /**
     * @notice The hook reverted, and with it the transfer.
     * @param reason A truncated prefix of the hook's revert data — at most 256 bytes. Copying it whole
     *        would let a hook charge the transfer's caller for an arbitrarily large `RETURNDATACOPY`,
     *        which is gas the published hook budget does not cover.
     */
    error ERC20TransferHookFailed(bytes reason);

    /// @notice The hook returned something other than its acknowledgement selector.
    error ERC20TransferHookNotAcknowledged(address hook);

    /// @notice Emitted when the hook target or its gas limit changes.
    event TransferHookUpdated(address indexed hook, uint32 gasLimit);

    /// @notice The contract called after every transfer, or the zero address if no hook is installed.
    function transferHook() external view returns (address);

    /// @notice The gas forwarded to the hook. An integrator should budget at least this much on top of a
    ///         plain transfer, plus the 1/64 the EVM withholds from every call.
    function transferHookGasLimit() external view returns (uint32);
}

/**
 * @title ITransferHookReceiver
 * @notice Implemented by the policy contract a token calls after each transfer.
 */
interface ITransferHookReceiver {
    /**
     * @notice Called after `value` has been credited to `to`.
     * @dev Revert to reject the transfer. Must return `ITransferHookReceiver.onTransfer.selector`; any
     *      other return value rejects the transfer too, so a contract cannot be made a hook by accident.
     *
     *      Balances are already settled when this runs, so `balanceOf(to)` reflects the transfer. The token
     *      holds a reentrancy guard for the duration, so calling back into the token's transfer path from
     *      here reverts.
     *
     * @param token The token making the call. Always `msg.sender`; passed so one hook can serve many tokens
     *        without an extra frame of indirection.
     * @param from The sender.
     * @param to The recipient.
     * @param value The amount **actually credited to `to`** — net of any transfer fee, not the amount named
     *        in the original `transfer` call.
     */
    function onTransfer(address token, address from, address to, uint256 value) external returns (bytes4);
}
