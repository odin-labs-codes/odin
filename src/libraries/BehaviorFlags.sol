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
 *      A flag is set whenever the corresponding extension is *installed*, not when it is currently
 *      *active*. A token with the transfer-fee extension installed and its rate at zero still reports
 *      `FEE_ON_TRANSFER`, because the fee authority can raise the rate at any time. False positives cost an
 *      integrator a slightly more defensive code path; false negatives cost them funds.
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

    /// @notice Every bit this library currently assigns meaning to. Bits outside this mask are reserved.
    uint256 internal constant ALL = FEE_ON_TRANSFER | REBASING | TRANSFER_HOOK | PAUSABLE | BLOCKLIST;
}
