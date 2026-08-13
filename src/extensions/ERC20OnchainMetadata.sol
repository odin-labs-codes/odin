// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20OnchainMetadata} from "../interfaces/IERC20OnchainMetadata.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC20ExtensionCore} from "./ERC20ExtensionCore.sol";

/**
 * @title ERC20OnchainMetadata
 * @notice Enumerable key/value metadata kept on chain, plus an ERC-1046 `tokenURI`.
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
    /// @custom:storage-location erc7201:berc.storage.OnchainMetadata
    struct OnchainMetadataStorage {
        string[] keys;
        mapping(string key => uint256 indexPlusOne) keyIndex;
        mapping(string key => string value) values;
        string uri;
    }

    // keccak256(abi.encode(uint256(keccak256("berc.storage.OnchainMetadata")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ONCHAIN_METADATA_STORAGE =
        0x7f43e00cd80e09c98e94c54ebb5284108c8e6054d7ccedb7528783861f303600;

    function _getOnchainMetadataStorage() private pure returns (OnchainMetadataStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ONCHAIN_METADATA_STORAGE
        }
    }

    function __ERC20OnchainMetadata_init() internal onlyInitializing {
        _registerExtension(ExtensionIds.ONCHAIN_METADATA, 0);
    }

    // -----------------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20OnchainMetadata
    function getMetadata(string calldata key) external view virtual returns (string memory) {
        return _getOnchainMetadataStorage().values[key];
    }

    /// @inheritdoc IERC20OnchainMetadata
    function metadataKeys() external view virtual returns (string[] memory) {
        return _getOnchainMetadataStorage().keys;
    }

    /// @inheritdoc IERC20OnchainMetadata
    function metadataKeyCount() external view virtual returns (uint256) {
        return _getOnchainMetadataStorage().keys.length;
    }

    /// @inheritdoc IERC20OnchainMetadata
    function metadataKeyAt(uint256 index) external view virtual returns (string memory) {
        OnchainMetadataStorage storage $ = _getOnchainMetadataStorage();
        if (index >= $.keys.length) revert ERC20MetadataIndexOutOfBounds(index, $.keys.length);
        return $.keys[index];
    }

    /// @inheritdoc IERC20OnchainMetadata
    function tokenURI() external view virtual returns (string memory) {
        return _getOnchainMetadataStorage().uri;
    }

    /// @inheritdoc ERC20ExtensionCore
    function _extensionData(bytes4 extensionId) internal view virtual override returns (bytes memory) {
        if (extensionId == ExtensionIds.ONCHAIN_METADATA) {
            OnchainMetadataStorage storage $ = _getOnchainMetadataStorage();
            return abi.encode($.uri, $.keys.length);
        }
        return super._extensionData(extensionId);
    }

    // -----------------------------------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------------------------------

    /// @notice Sets or overwrites the value for `key`. An empty value is allowed; the key stays present.
    function setMetadata(string calldata key, string calldata value) external virtual {
        _authorizeExtensionConfig(ExtensionIds.ONCHAIN_METADATA);
        if (bytes(key).length == 0) revert ERC20MetadataInvalidKey();

        OnchainMetadataStorage storage $ = _getOnchainMetadataStorage();
        if ($.keyIndex[key] == 0) {
            $.keys.push(key);
            $.keyIndex[key] = $.keys.length;
        }
        $.values[key] = value;

        emit MetadataUpdated(keccak256(bytes(key)), key, value);
        _emitExtensionConfigured(ExtensionIds.ONCHAIN_METADATA);
    }

    /// @notice Deletes `key` from the store. Reverts if it is not present.
    function removeMetadata(string calldata key) external virtual {
        _authorizeExtensionConfig(ExtensionIds.ONCHAIN_METADATA);

        OnchainMetadataStorage storage $ = _getOnchainMetadataStorage();
        uint256 indexPlusOne = $.keyIndex[key];
        if (indexPlusOne == 0) revert ERC20MetadataKeyNotFound(key);

        // Swap-and-pop: key order is documented as unstable, so moving the last key into the gap is fine.
        uint256 lastIndex = $.keys.length - 1;
        if (indexPlusOne - 1 != lastIndex) {
            string memory moved = $.keys[lastIndex];
            $.keys[indexPlusOne - 1] = moved;
            $.keyIndex[moved] = indexPlusOne;
        }
        $.keys.pop();
        delete $.keyIndex[key];
        delete $.values[key];

        emit MetadataRemoved(keccak256(bytes(key)), key);
        _emitExtensionConfigured(ExtensionIds.ONCHAIN_METADATA);
    }

    /// @notice Sets the ERC-1046 metadata document URI. Secondary to the on-chain store.
    function setTokenURI(string calldata newTokenURI) external virtual {
        _authorizeExtensionConfig(ExtensionIds.ONCHAIN_METADATA);

        _getOnchainMetadataStorage().uri = newTokenURI;

        emit TokenURIUpdated(newTokenURI);
        _emitExtensionConfigured(ExtensionIds.ONCHAIN_METADATA);
    }
}
