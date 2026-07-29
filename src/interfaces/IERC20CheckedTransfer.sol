// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC20CheckedTransfer
 * @notice Transfers that state what the caller expects and revert if the token does something else.
 *
 * @dev Token-2022's `transfer_checked` exists because a plain transfer commits the sender to whatever the
 *      mint's configuration happens to be at execution time, which is not the configuration they read when
 *      they signed. The same gap exists on any token whose transfer is not the identity function: between
 *      simulation and inclusion an authority can raise the fee, and the sender pays the new one.
 *
 *      ## `minAmountReceived` is the guard; the epoch is not
 *
 *      There is only one way for a transfer to go wrong quietly, and that is for less value to arrive than
 *      the sender expected. Everything else a configuration change can do — a new blocklist entry, a paused
 *      token, a swapped hook — makes the transfer *revert*, which is loud and costs the sender nothing but
 *      gas. So the guard that matters is a floor on what arrives, and `minAmountReceived` states it in the
 *      only unit that cannot be gamed: the recipient's actual balance change, measured across the call.
 *
 *      Measuring rather than predicting also gets the awkward cases right for free. If `to` is the fee
 *      vault, it is credited by both the fee leg and the main leg, and the measurement says `amount`
 *      arrived, which it did. A predicted figure would have had to special-case that.
 *
 *      `expectedConfigurationEpoch` is offered for callers who want the stronger and much more brittle
 *      claim that the configuration they read is the configuration that executes. It is opt-in — pass `0`
 *      to skip the check — because it fails on changes that have nothing to do with the caller's transfer:
 *      exempting an unrelated address bumps the epoch, and an authority that touches configuration every
 *      block would make every epoch-checked transfer revert. Use it when you have audited a specific
 *      configuration and will not transact under any other. Use `minAmountReceived` otherwise.
 *
 *      ## Why both a `transfer` and a `transferFrom` form
 *
 *      Routers, vaults and anything holding an allowance move value with `transferFrom`, and those are
 *      precisely the integrators a fee-bearing token breaks. A checked API that only covered `transfer`
 *      would not be reachable from the code paths that need it.
 */
interface IERC20CheckedTransfer {
    /// @notice Less value arrived than the caller was willing to accept.
    error ERC20CheckedTransferUnderMinimum(uint256 received, uint256 minAmountReceived);

    /// @notice Configuration changed between the caller reading it and this call executing.
    error ERC20CheckedTransferEpochMismatch(uint64 expected, uint64 actual);

    /// @notice Emitted whenever a change lands that could alter the outcome of some transfer.
    event ConfigurationEpochAdvanced(uint64 epoch);

    /**
     * @notice Counter over this token's own extension configuration.
     *
     * @dev Starts at 1, so `0` is free to mean "do not check" in the checked transfer functions. Fee,
     *      restriction and hook settings advance it, including per-account ones such as a fee exemption or
     *      a freeze. Metadata changes do not: they are loud, but they cannot change what a transfer does.
     *
     *      **It counts setter calls on this token, and nothing beyond them.** Three things can change what
     *      a transfer does while the epoch stands still:
     *
     *      - the hook contract's own internal state, which it may change on any call;
     *      - an upgrade behind the hook, if the configured hook is itself a proxy;
     *      - an upgrade behind this token, on a deployment that declares `UPGRADEABLE`.
     *
     *      So a matching epoch means "the same configuration I read is installed", never "the token will
     *      behave as it did when I read it". On an `UPGRADEABLE` token it is worth less again, because an
     *      upgrade can change what advancing the epoch even means. A caller who needs the stronger claim
     *      wants a verified immutable runtime and a hook whose code they have read — and even then,
     *      `minAmountReceived` is the guard that binds the outcome rather than the configuration.
     */
    function configurationEpoch() external view returns (uint64);

    /**
     * @notice Transfers `amount`, reverting unless at least `minAmountReceived` reaches `to`.
     * @param minAmountReceived Floor on `to`'s measured balance increase. Pass `amount` to demand an exact
     *        transfer, or a computed figure to allow a known fee.
     * @param expectedConfigurationEpoch Pass `0` to skip the check, or the epoch the caller read.
     * @return received `to`'s actual balance increase. A self-transfer nets to zero, or to zero with a fee
     *         charged, because the sender's own balance is what fell.
     */
    function transferChecked(address to, uint256 amount, uint256 minAmountReceived, uint64 expectedConfigurationEpoch)
        external
        returns (uint256 received);

    /**
     * @notice The {transferChecked} guarantee, applied to an allowance-spending transfer.
     * @dev The allowance is spent on `amount` — the gross figure, before any fee — matching what
     *      `transferFrom` itself spends.
     */
    function transferFromChecked(
        address from,
        address to,
        uint256 amount,
        uint256 minAmountReceived,
        uint64 expectedConfigurationEpoch
    ) external returns (uint256 received);
}
