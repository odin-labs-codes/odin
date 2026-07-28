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
 *      ## `minAmountReceived` is the guard
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
 *      ## Why both a `transfer` and a `transferFrom` form
 *
 *      Routers, vaults and anything holding an allowance move value with `transferFrom`, and those are
 *      precisely the integrators a fee-bearing token breaks. A checked API that only covered `transfer`
 *      would not be reachable from the code paths that need it.
 */
interface IERC20CheckedTransfer {
    /// @notice Less value arrived than the caller was willing to accept.
    error ERC20CheckedTransferUnderMinimum(uint256 received, uint256 minAmountReceived);

    /**
     * @notice Transfers `amount`, reverting unless at least `minAmountReceived` reaches `to`.
     * @param minAmountReceived Floor on `to`'s measured balance increase. Pass `amount` to demand an exact
     *        transfer, or a computed figure to allow a known fee.
     * @return received `to`'s actual balance increase. A self-transfer nets to zero, or to zero with a fee
     *         charged, because the sender's own balance is what fell.
     */
    function transferChecked(address to, uint256 amount, uint256 minAmountReceived)
        external
        returns (uint256 received);

    /**
     * @notice The {transferChecked} guarantee, applied to an allowance-spending transfer.
     * @dev The allowance is spent on `amount` — the gross figure, before any fee — matching what
     *      `transferFrom` itself spends.
     */
    function transferFromChecked(address from, address to, uint256 amount, uint256 minAmountReceived)
        external
        returns (uint256 received);
}
