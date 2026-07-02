// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20OnchainMetadata} from "../interfaces/IERC20OnchainMetadata.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC20ExtensionCore} from "./ERC20ExtensionCore.sol";

/**
 * @title ERC20OnchainMetadata
 * @notice Enumerable key/value metadata kept on chain.
 *
 * @dev This module never touches the transfer path and declares no behaviour flags, which is the point:
 *      metadata is the cheap kind of heavy. Reading and writing strings costs computation, and computation
 *      on an L2 is close to free; what it costs an integrator is nothing at all, because no transfer
 *      behaves differently because of it.
 *
 *      `name`, `symbol` and `decimals` are deliberately left alone — they stay exactly where ERC-20 put
 *      them. This store is for everything ERC-20 has no slot for.
 */
abstract contract ERC20OnchainMetadata is ERC20ExtensionCore, IERC20OnchainMetadata {
    string[] private _keys;
    mapping(string key => uint256 indexPlusOne) private _keyIndex;
    mapping(string key => string value) private _values;

    function __ERC20OnchainMetadata_init() internal onlyInitializing {
        _registerExtension(ExtensionIds.ONCHAIN_METADATA, 0);
    }

    // -----------------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20OnchainMetadata
    function getMetadata(string calldata key) external view virtual returns (string memory) {
        return _values[key];
    }

    /// @inheritdoc IERC20OnchainMetadata
    function metadataKeys() external view virtual returns (string[] memory) {
        return _keys;
    }

    /// @inheritdoc IERC20OnchainMetadata
    function metadataKeyCount() external view virtual returns (uint256) {
        return _keys.length;
    }

    /// @inheritdoc IERC20OnchainMetadata
    function metadataKeyAt(uint256 index) external view virtual returns (string memory) {
        if (index >= _keys.length) revert ERC20MetadataIndexOutOfBounds(index, _keys.length);
        return _keys[index];
    }

    // -----------------------------------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------------------------------

    /// @notice Sets or overwrites the value for `key`. An empty value is allowed; the key stays present.
    function setMetadata(string calldata key, string calldata value) external virtual {
        _authorizeExtensionConfig(ExtensionIds.ONCHAIN_METADATA);
        if (bytes(key).length == 0) revert ERC20MetadataInvalidKey();

        if (_keyIndex[key] == 0) {
            _keys.push(key);
            _keyIndex[key] = _keys.length;
        }
        _values[key] = value;

        emit MetadataUpdated(keccak256(bytes(key)), key, value);
    }

    /// @notice Deletes `key` from the store. Reverts if it is not present.
    function removeMetadata(string calldata key) external virtual {
        _authorizeExtensionConfig(ExtensionIds.ONCHAIN_METADATA);

        uint256 indexPlusOne = _keyIndex[key];
        if (indexPlusOne == 0) revert ERC20MetadataKeyNotFound(key);

        // Swap-and-pop: key order is documented as unstable, so moving the last key into the gap is fine.
        uint256 lastIndex = _keys.length - 1;
        if (indexPlusOne - 1 != lastIndex) {
            string memory moved = _keys[lastIndex];
            _keys[indexPlusOne - 1] = moved;
            _keyIndex[moved] = indexPlusOne;
        }
        _keys.pop();
        delete _keyIndex[key];
        delete _values[key];

        emit MetadataRemoved(keccak256(bytes(key)), key);
    }
}
