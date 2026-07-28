// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @notice Everything the installed extensions know about one account, in one struct.
 * @dev The fields are the union of the per-account state the reference modules keep. A field belonging to
 *      an extension that is not installed reads as its neutral value (`false`), never as an error, so a
 *      caller can read this without first checking {IERC20Extensions-hasExtension}.
 * @param frozen The restriction extension has barred this account from transferring. Corresponds to
 *        Token-2022's frozen account state.
 * @param feeExempt Transfers touching this account are not charged a transfer fee.
 * @param configuredAt Unix timestamp of the last change to any of the above; `0` if never configured.
 */
struct AccountState {
    bool frozen;
    bool feeExempt;
    uint64 configuredAt;
}

/**
 * @title IERC20AccountState
 * @notice Token-2022 keeps extension state on the account, not only on the mint. This is the equivalent:
 *         one call that returns every per-account flag the token's extensions maintain.
 *
 * @dev Without this, an integrator screening an account has to know which extensions exist, ask each one
 *      separately, and handle a revert from the ones that are not installed. Three round trips and a
 *      conditional become one call that is always safe to make.
 */
interface IERC20AccountState {
    /// @notice The per-account extension state for `account`.
    function accountState(address account) external view returns (AccountState memory);
}
