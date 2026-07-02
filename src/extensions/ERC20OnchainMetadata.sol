// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20OnchainMetadata} from "../interfaces/IERC20OnchainMetadata.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC20ExtensionCore} from "./ERC20ExtensionCore.sol";

/**
 * @title ERC20OnchainMetadata
 * @notice Key/value metadata kept on chain.
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
    mapping(string key => string value) private _values;

    function __ERC20OnchainMetadata_init() internal onlyInitializing {
        _registerExtension(ExtensionIds.ONCHAIN_METADATA, 0);
    }

    /// @inheritdoc IERC20OnchainMetadata
    function getMetadata(string calldata key) external view virtual returns (string memory) {
        return _values[key];
    }

    /// @notice Sets or overwrites the value for `key`. An empty value is allowed; the key stays present.
    function setMetadata(string calldata key, string calldata value) external virtual {
        _authorizeExtensionConfig(ExtensionIds.ONCHAIN_METADATA);
        if (bytes(key).length == 0) revert ERC20MetadataInvalidKey();

        _values[key] = value;

        emit MetadataUpdated(keccak256(bytes(key)), key, value);
    }
}
