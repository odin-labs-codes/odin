// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC20OnchainMetadata
 * @notice Enumerable key/value metadata stored on chain.
 *
 * @dev Storing strings on chain is the kind of expensive that stopped mattering on L2. Storing them off
 *      chain behind a URL is the kind of cheap that costs an integrator a fetch, a parse, and a trust
 *      assumption. This extension makes the on-chain copy the default.
 */
interface IERC20OnchainMetadata {
    /// @notice A metadata key must be a non-empty string.
    error ERC20MetadataInvalidKey();

    /// @notice The key is not present in the on-chain store.
    error ERC20MetadataKeyNotFound(string key);

    /// @notice The requested key index is past the end of the store.
    error ERC20MetadataIndexOutOfBounds(uint256 index, uint256 length);

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

    /// @notice Emitted when a key is deleted from the on-chain store. Carries the key for the same reason.
    event MetadataRemoved(bytes32 indexed keyHash, string key);

    /// @notice The value for `key`, or the empty string if the key is not present.
    function getMetadata(string calldata key) external view returns (string memory);

    /**
     * @notice Every key currently present, in unspecified order. Order is not stable across removals.
     * @dev Returns the whole array, so its cost grows with the store and a metadata authority that adds
     *      keys without limit can push it past what a node will serve. Nothing on the transfer path reads
     *      it, so the token cannot be bricked this way — but an indexer that depends on this one call can
     *      be, which is what {metadataKeyCount} and {metadataKeyAt} exist to avoid.
     */
    function metadataKeys() external view returns (string[] memory);

    /// @notice How many keys the store holds. Pair with {metadataKeyAt} to page through them.
    function metadataKeyCount() external view returns (uint256);

    /// @notice The key at `index`. Reverts past the end; indices shift when a key is removed.
    function metadataKeyAt(uint256 index) external view returns (string memory);
}
