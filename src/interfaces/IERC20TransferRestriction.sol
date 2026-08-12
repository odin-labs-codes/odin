// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC20TransferRestriction
 * @notice ERC-1404's signatures, reused verbatim.
 *
 * @dev This is deliberately not a new interface. Compliance tooling — transfer agents, KYC providers,
 *      security-token platforms — already speaks ERC-1404, and a token that answers those two functions
 *      drops into that tooling with no adapter. Inventing a better-shaped equivalent would trade real
 *      interoperability for a marginally nicer signature.
 *
 *      Restriction codes are per-token. The codes this framework's reference module uses are documented on
 *      `ERC20TransferRestriction`; a caller should render {messageForTransferRestriction} rather than
 *      hard-coding meanings for anything but `0`.
 *
 *      Extension data encoding for {IERC20Extensions-extensionData}: `abi.encode(bool paused)`.
 */
interface IERC20TransferRestriction {
    /// @notice A transfer was attempted that {detectTransferRestriction} would have rejected.
    error ERC20TransferRestricted(uint8 restrictionCode);

    /// @notice Emitted when transfers are globally paused or unpaused.
    event TransferPauseUpdated(bool paused);

    /// @notice Emitted when an individual account is frozen or unfrozen.
    event AccountFrozen(address indexed account, bool frozen);

    /**
     * @notice Whether this transfer would be rejected, and why.
     * @return restrictionCode `0` if the transfer is allowed; any other value is a rejection reason.
     */
    function detectTransferRestriction(address from, address to, uint256 amount)
        external
        view
        returns (uint8 restrictionCode);

    /// @notice A human-readable explanation of a code returned by {detectTransferRestriction}.
    function messageForTransferRestriction(uint8 restrictionCode) external view returns (string memory);
}
