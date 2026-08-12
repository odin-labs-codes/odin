// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC20OnchainMetadata
 * @notice Enumerable key/value metadata stored on chain, with an ERC-1046 `tokenURI` alongside it.
 *
 * @dev **Precedence: the on-chain key/value store is authoritative.** If a key appears both here and in the
 *      JSON document at {tokenURI}, the value returned by {getMetadata} wins and the document's value must
 *      be ignored. The URI exists for data that is genuinely too large or too rich for storage — artwork,
 *      long descriptions, external links — and as a compatibility path for ERC-1046 consumers.
 *
 *      Storing strings on chain is the kind of expensive that stopped mattering on L2. Storing them off
 *      chain behind a URL is the kind of cheap that costs an integrator a fetch, a parse, and a trust
 *      assumption. This extension makes the on-chain copy the default and the URI the fallback.
 *
 *      Extension data encoding for {IERC20Extensions-extensionData}:
 *      `abi.encode(string tokenURI, uint256 keyCount)`.
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
     *      rides in the data so a consumer that knows none of them can still read what changed.
     *
     *      Carrying both is not redundant. An `indexed string` is *only* its hash — the string never
     *      reaches the log — so an indexer following events alone could never recover the key, and
     *      {metadataKeys} does not close the gap for a key that was added and removed before the indexer
     *      looked.
     * @param keyHash `keccak256(bytes(key))`, for filtering.
     * @param key The key itself, readable.
     */
    event MetadataUpdated(bytes32 indexed keyHash, string key, string value);

    /// @notice Emitted when a key is deleted from the on-chain store. Carries the key for the same reason.
    event MetadataRemoved(bytes32 indexed keyHash, string key);

    /// @notice Emitted when the ERC-1046 token URI changes.
    event TokenURIUpdated(string tokenURI);

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

    /**
     * @notice ERC-1046 metadata document URI.
     * @dev Secondary to the on-chain store; see the note on precedence above.
     */
    function tokenURI() external view returns (string memory);
}
