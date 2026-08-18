// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC721OperatorRestriction
 * @notice A collection that can refuse a transfer because of *who asked for it*, and says so in advance.
 *
 * @dev This is the extension that has no fungible counterpart, and the reason the framework is worth
 *      porting to ERC-721 at all.
 *
 *      Everything an ERC-20 does to surprise an integrator — withholding a fee, pausing, freezing — shows
 *      up when the integrator simulates a transfer. An operator policy does not. The collection screens the
 *      **caller**, so a marketplace can simulate the owner's transfer all day, watch it succeed, list the
 *      token, and then have settlement revert because the address doing the asking is its own exchange
 *      contract. The failure surfaces at the worst possible moment and looks like a bug in the marketplace.
 *
 *      So the policy is readable before it is enforced. {isOperatorAllowed} answers for any address,
 *      including the caller's own, and answers it as a `view` — which is the entire point.
 *
 *      Two things this deliberately does **not** do:
 *
 *      - **It does not gate `approve` or `setApprovalForAll`.** A barred operator can still be approved;
 *        the transfer is what fails. Gating approval hides the refusal one step earlier and makes the
 *        collection's behaviour depend on which of two calls you make first, and an integrator that reads
 *        {isOperatorAllowed} before asking for approval never needs it.
 *      - **It does not screen the recipient.** A policy that refused transfers *to* an address would be a
 *        blocklist, which is a different flag with different semantics.
 */
interface IERC721OperatorRestriction {
    /// @notice Whether the allowlist is now consulted on operator transfers.
    event OperatorAllowlistEnforced(bool enforced);

    /// @notice One operator's standing changed. Meaningful only while the allowlist is enforced.
    event OperatorAllowed(address indexed operator, bool allowed);

    /// @notice The caller is not the owner and is not on the allowlist.
    error ERC721OperatorNotAllowed(address operator);

    /**
     * @notice Whether `operator` may move tokens it does not own.
     * @dev Call this with your own exchange address before listing. Answers `true` for every address while
     *      the allowlist is not enforced, so a single call covers both states and no caller has to branch
     *      on {operatorAllowlistEnforced} first.
     *
     *      A token's owner is never screened, so this answering `false` does not mean the token cannot
     *      move — it means it cannot move *through you*.
     */
    function isOperatorAllowed(address operator) external view returns (bool);

    /// @notice Whether the allowlist is being consulted at all. `false` means every operator may transfer.
    function operatorAllowlistEnforced() external view returns (bool);
}
