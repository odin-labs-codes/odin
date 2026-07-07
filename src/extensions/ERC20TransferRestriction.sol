// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20TransferRestriction} from "../interfaces/IERC20TransferRestriction.sol";
import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC20ExtensionCore} from "./ERC20ExtensionCore.sol";

/**
 * @title ERC20TransferRestriction
 * @notice A global pause, exposed through ERC-1404's two functions.
 *
 * @dev The check runs in phase 1, before anything has moved or been emitted: a transfer that is not allowed
 *      to happen must leave no trace of having been attempted.
 */
abstract contract ERC20TransferRestriction is ERC20ExtensionCore, IERC20TransferRestriction {
    /// @notice The transfer is allowed.
    uint8 public constant RESTRICTION_OK = 0;

    /// @notice All transfers are currently paused.
    uint8 public constant RESTRICTION_PAUSED = 1;

    bool private _paused;

    function __ERC20TransferRestriction_init() internal onlyInitializing {
        _registerExtension(ExtensionIds.TRANSFER_RESTRICTION, BehaviorFlags.PAUSABLE);
    }

    // -----------------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20TransferRestriction
    function detectTransferRestriction(address, address, uint256) public view virtual returns (uint8) {
        if (_paused) return RESTRICTION_PAUSED;
        return RESTRICTION_OK;
    }

    /// @inheritdoc IERC20TransferRestriction
    function messageForTransferRestriction(uint8 restrictionCode) public view virtual returns (string memory) {
        if (restrictionCode == RESTRICTION_OK) return "Transfer allowed";
        if (restrictionCode == RESTRICTION_PAUSED) return "Transfers are paused";
        return "Unknown restriction code";
    }

    /// @notice Whether all transfers are currently paused.
    function transfersPaused() public view virtual returns (bool) {
        return _paused;
    }

    /// @inheritdoc ERC20ExtensionCore
    function _extensionData(bytes4 extensionId) internal view virtual override returns (bytes memory) {
        if (extensionId == ExtensionIds.TRANSFER_RESTRICTION) {
            return abi.encode(_paused);
        }
        return super._extensionData(extensionId);
    }

    // -----------------------------------------------------------------------------------------------
    // Transfer pipeline — phase 1
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc ERC20ExtensionCore
    function _checkTransferAllowed(address from, address to, uint256 value) internal view virtual override {
        uint8 code = detectTransferRestriction(from, to, value);
        if (code != RESTRICTION_OK) revert ERC20TransferRestricted(code);
        super._checkTransferAllowed(from, to, value);
    }

    // -----------------------------------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------------------------------

    /// @notice Pauses or unpauses all transfers.
    function setTransfersPaused(bool paused) external virtual {
        _authorizeExtensionConfig(ExtensionIds.TRANSFER_RESTRICTION);

        _paused = paused;

        emit TransferPauseUpdated(paused);
        _emitExtensionConfigured(ExtensionIds.TRANSFER_RESTRICTION);
    }
}
