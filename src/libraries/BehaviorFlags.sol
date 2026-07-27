// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title BehaviorFlags
 * @notice The vocabulary a token uses to declare, in a single word, every way it departs from the
 *         behaviour an integrator would assume from a plain ERC-20.
 *
 * @dev Solidity forbids constants inside an `interface`, so the flag values live here rather than on
 *      {IERC20Behavior}. Integrators are expected to copy this library verbatim or inline the values.
 *
 *      Two rules make the flags worth reading:
 *
 *      1. A flag is set whenever the corresponding extension is *installed*, not when it is currently
 *         *active*. A token with the transfer-fee extension installed and its rate at zero still reports
 *         `FEE_ON_TRANSFER`, because the fee authority can raise the rate at any time. False positives
 *         cost an integrator a slightly more defensive code path; false negatives cost them funds.
 *
 *      2. Because the extension set is fixed at deployment (see {IERC20Extensions-extensions}), the flag
 *         word is fixed at deployment too — with one exception, which the vocabulary names itself. A token
 *         declaring `UPGRADEABLE` can have its code replaced, and a replacement is not bound by the set the
 *         old code sealed. So the word is safe to cache forever exactly when `UPGRADEABLE` is clear, and
 *         otherwise only as far as the upgrade authority is trusted.
 */
library BehaviorFlags {
    /// @notice The recipient receives less than the amount named in the `transfer` call.
    uint256 internal constant FEE_ON_TRANSFER = 1 << 0;

    /// @notice `balanceOf` can change without a `Transfer` event naming the account.
    uint256 internal constant REBASING = 1 << 1;

    /// @notice A transfer makes a call into another contract, which may revert or consume gas.
    uint256 internal constant TRANSFER_HOOK = 1 << 2;

    /// @notice All transfers can be halted by an authority.
    uint256 internal constant PAUSABLE = 1 << 3;

    /// @notice Individual accounts can be barred from transferring by an authority.
    uint256 internal constant BLOCKLIST = 1 << 4;

    /// @notice The code behind this address can be replaced, so every other flag may change.
    uint256 internal constant UPGRADEABLE = 1 << 6;

    /// @notice Every bit this library currently assigns meaning to. Bits outside this mask are reserved.
    uint256 internal constant ALL = FEE_ON_TRANSFER | REBASING | TRANSFER_HOOK | PAUSABLE | BLOCKLIST | UPGRADEABLE;
}
