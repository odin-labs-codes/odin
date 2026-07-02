// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC20OnchainMetadata
 * @notice Key/value metadata stored on chain.
 *
 * @dev Storing strings on chain is the kind of expensive that stopped mattering on L2. Storing them off
 *      chain behind a URL is the kind of cheap that costs an integrator a fetch, a parse, and a trust
 *      assumption. This extension makes the on-chain copy the default.
 */
interface IERC20OnchainMetadata {
    /// @notice A metadata key must be a non-empty string.
    error ERC20MetadataInvalidKey();

    /**
     * @notice Emitted when a key's value is set or changed.
     * @dev The hash is indexed so a consumer can filter for one key it already knows; the plaintext `key`
     *      rides in the data so a consumer that knows none of them can still read what changed. An
     *      `indexed string` is *only* its hash — the string never reaches the log — so carrying both is not
     *      redundant.
     * @param keyHash `keccak256(bytes(key))`, for filtering.
     * @param key The key itself, readable.
     */
    event MetadataUpdated(bytes32 indexed keyHash, string key, string value);

    /// @notice The value for `key`, or the empty string if the key is not present.
    function getMetadata(string calldata key) external view returns (string memory);
}
