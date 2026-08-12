// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC20Extensions
 * @notice Discovery surface for the extensions a token has installed.
 *
 * @dev The set returned by {extensions} is fixed in the constructor and can never change. That immutability
 *      is the whole point: an integrator can read it once, cache it next to the token address, and never
 *      re-check. A set that could grow after deployment would have to be re-read before every interaction,
 *      which costs more than it saves and earns no trust.
 *
 *      Individual extensions remain configurable by their authority. Token-level changes — a fee rate, a
 *      pause, a hook — emit {ExtensionConfigured} carrying the extension's whole configuration, so an
 *      indexer following that one event holds a current view of them without polling.
 *
 *      **Per-account state is not covered by that event.** Exemptions and freezes emit their own typed
 *      events (`FeeExemptionUpdated`, `AccountFrozen`) and are read back with
 *      {IERC20AccountState-accountState}. They are left out deliberately: there is one such change per
 *      account rather than one per token, and duplicating each into a generic event would double the log
 *      cost of every compliance action to carry what the typed event already carried.
 */
interface IERC20Extensions {
    /// @notice The extension is not installed on this token.
    error ERC20ExtensionNotEnabled(bytes4 extensionId);

    /**
     * @notice Emitted when an extension's token-level configuration changes.
     * @dev Not emitted for per-account state; see the note on this interface for why, and what to follow
     *      instead. Note also that `data` is whatever {extensionData} returns, which for an extension
     *      holding an unbounded store is a summary rather than the store — the metadata extension reports
     *      its token URI and key count, and its `MetadataUpdated` / `MetadataRemoved` events carry the
     *      individual entries.
     * @param extensionId The extension whose configuration changed.
     * @param data The extension's configuration after the change, encoded exactly as {extensionData}
     *        would return it.
     */
    event ExtensionConfigured(bytes4 indexed extensionId, bytes data);

    /**
     * @notice The identifiers of every extension installed on this token.
     * @dev Fixed at deployment. Order is the order of installation and is also fixed.
     */
    function extensions() external view returns (bytes4[] memory);

    /// @notice Whether a specific extension is installed. Fixed at deployment.
    function hasExtension(bytes4 extensionId) external view returns (bool);

    /**
     * @notice The current configuration of one extension, ABI-encoded per that extension's documentation.
     * @dev Reverts with {ERC20ExtensionNotEnabled} if the extension is not installed, so a caller can
     *      distinguish "installed but unconfigured" (empty bytes) from "not installed" (revert).
     */
    function extensionData(bytes4 extensionId) external view returns (bytes memory);
}
