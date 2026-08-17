// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title BehaviorFlags
 * @notice The vocabulary a token uses to declare, in a single word, every way it departs from the
 *         behaviour an integrator would assume from a plain ERC-20 or ERC-721.
 *
 * @dev One vocabulary covers both token types on purpose. An integrator holds one copy of this library and
 *      reads one word, whatever the token turns out to be; a flag that cannot apply to a given type is
 *      simply never set by it. Solidity forbids constants inside an `interface`, so the values live here
 *      rather than on {IERC20Behavior} or {IERC721Behavior}.
 *
 *      Two rules make the flags worth reading:
 *
 *      1. A flag is set whenever the corresponding extension is *installed*, not when it is currently
 *         *active*. A token with the transfer-fee extension installed and its rate at zero still reports
 *         `FEE_ON_TRANSFER`, because the fee authority can raise the rate at any time. False positives
 *         cost an integrator a slightly more defensive code path; false negatives cost them funds.
 *
 *      2. Because the extension set is fixed at deployment (see {IERC20Extensions-extensions} and
 *         {IERC721Extensions-extensions}), the flag
 *         word is fixed at deployment too — with one exception, which the vocabulary names itself. A token
 *         declaring `UPGRADEABLE` can have its code replaced, and a replacement is not bound by the set the
 *         old code sealed. So the word is safe to cache forever exactly when `UPGRADEABLE` is clear, and
 *         otherwise only as far as the upgrade authority is trusted. A verified clone of an immutable
 *         runtime is the case where "forever" is a fact about the bytecode rather than a promise.
 */
library BehaviorFlags {
    /**
     * @notice The recipient receives less than the amount named in the `transfer` call.
     * @dev The word is laid out in three bands, in descending order of how easily an integrator can find
     *      the behaviour out on their own:
     *
     *      - **Bits 0-5** are the token's own observable behaviour. Five of them change what a transfer
     *        does and show up in a simulation; `REBASING` shows up instead as a balance that moved with no
     *        `Transfer` naming the account.
     *      - **Bits 6-8** are powers an authority holds over the token. Nothing reveals these until they
     *        are used, which is what makes them the ones discovered late.
     *      - **Bits 9 and up** are behaviours only a non-fungible token can have.
     */
    uint256 internal constant FEE_ON_TRANSFER = 1 << 0;

    /// @notice `balanceOf` can change without a `Transfer` event naming the account.
    uint256 internal constant REBASING = 1 << 1;

    /// @notice A transfer makes a call into another contract, which may revert or consume gas.
    uint256 internal constant TRANSFER_HOOK = 1 << 2;

    /// @notice All transfers can be halted by an authority.
    uint256 internal constant PAUSABLE = 1 << 3;

    /// @notice Individual accounts can be barred from transferring by an authority.
    uint256 internal constant BLOCKLIST = 1 << 4;

    /// @notice Transfers between two non-zero addresses always revert; only mint and burn move value.
    uint256 internal constant NON_TRANSFERABLE = 1 << 5;

    /// @notice The code behind this address can be replaced, so every other flag may change.
    uint256 internal constant UPGRADEABLE = 1 << 6;

    /// @notice An authority can create supply. Every holder's share can be diluted without warning.
    uint256 internal constant MINTABLE = 1 << 7;

    /**
     * @notice An authority can destroy any account's balance without that account's consent.
     * @dev Token-2022's Permanent Delegate is a partial analogue and a strictly larger power: it can
     *      transfer an arbitrary account's balance as well as burn it, while this flag names only the
     *      destruction, which is all the reference tokens can do. This is also not `BLOCKLIST`: a freeze
     *      stops value moving and is reversible, while this takes the value.
     */
    uint256 internal constant SEIZABLE = 1 << 8;

    /**
     * @notice An authority can rewrite what a token *is* after it has been minted.
     * @dev Non-fungible tokens only. `tokenURI` is not decoration: it is where the traits live, and anyone
     *      pricing a token — a lending protocol taking it as collateral, an index weighting a collection —
     *      is pricing metadata that this flag says can be replaced underneath them. Nothing about the token
     *      moves when it happens, so no transfer simulation and no balance check will ever show it.
     *
     *      Set while the metadata module is installed, whether or not the authority has since frozen the
     *      collection. `metadataFrozen()` reports the current state; a freeze is one-way, so a collection
     *      that answers `true` will answer `true` forever.
     */
    uint256 internal constant METADATA_MUTABLE = 1 << 10;

    /// @notice Every bit this library currently assigns meaning to. Bits outside this mask are reserved.
    uint256 internal constant ALL = FEE_ON_TRANSFER | REBASING | TRANSFER_HOOK | PAUSABLE | BLOCKLIST
        | NON_TRANSFERABLE | UPGRADEABLE | MINTABLE | SEIZABLE | METADATA_MUTABLE;

    /**
     * @notice Returns the first pair of declared behaviours that contradict each other, or `(0, 0)` if
     *         the word is self-consistent.
     * @dev This is the single source of truth for the forbidden-combination table in the README, and is
     *      evaluated once at deployment by each core's `_sealExtensions`. Keeping it here rather than in
     *      the cores lets an integrator run the same check against a token they did not deploy.
     *
     *      Every entry below shares one rationale: `NON_TRANSFERABLE` means the transfer path is
     *      unreachable, so any behaviour that only manifests during a transfer is dead code that
     *      nonetheless scares integrators away. Declaring both is never useful and always misleading.
     */
    function conflictingPair(uint256 flags) internal pure returns (uint256 first, uint256 second) {
        if (flags & NON_TRANSFERABLE != 0) {
            if (flags & FEE_ON_TRANSFER != 0) return (NON_TRANSFERABLE, FEE_ON_TRANSFER);
            if (flags & TRANSFER_HOOK != 0) return (NON_TRANSFERABLE, TRANSFER_HOOK);
        }
        return (0, 0);
    }
}
