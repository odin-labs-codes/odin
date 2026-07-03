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
 */
interface IERC20Extensions {
    /// @notice The extension is not installed on this token.
    error ERC20ExtensionNotEnabled(bytes4 extensionId);

    /**
     * @notice Emitted when an extension's token-level configuration changes.
     * @dev `data` is whatever {extensionData} returns, which for an extension holding an unbounded store is
     *      a summary rather than the store — the metadata extension reports its token URI and key count, and
     *      its `MetadataUpdated` / `MetadataRemoved` events carry the individual entries.
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
