// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC721Extensions
 * @notice Which extension modules this collection installed, and what each one is configured to do.
 *
 * @dev Where {IERC721Behavior} answers "what does this collection do", this answers "which code is doing
 *      it, and with what settings". The set is fixed when the collection is deployed and can never grow or
 *      shrink afterwards, which is what makes a single read worth caching.
 */
interface IERC721Extensions {
    /**
     * @notice The configuration of one extension changed.
     * @param extensionId The extension, from {ExtensionIds}.
     * @param data The extension's full configuration *after* the change, in the same encoding
     *        {extensionData} returns — so a follower never has to call back to learn the new state.
     */
    event ExtensionConfigured(bytes4 indexed extensionId, bytes data);

    /// @notice Every installed extension, in registration order. Fixed at deployment.
    function extensions() external view returns (bytes4[] memory);

    /// @notice Whether one extension is installed.
    function hasExtension(bytes4 extensionId) external view returns (bool);

    /**
     * @notice The current configuration of one installed extension, ABI-encoded.
     * @dev Reverts if the extension is not installed, which keeps "installed but unconfigured" — empty
     *      bytes — distinguishable from "not installed at all".
     */
    function extensionData(bytes4 extensionId) external view returns (bytes memory);
}
