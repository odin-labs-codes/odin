// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20TransferRestriction} from "../interfaces/IERC20TransferRestriction.sol";
import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC20ExtensionCore} from "./ERC20ExtensionCore.sol";

/**
 * @title ERC20TransferRestriction
 * @notice A global pause and a per-account freeze, exposed through ERC-1404's two functions.
 *
 * @dev The check runs in phase 1, before anything has moved or been emitted: a transfer that is not allowed
 *      to happen must leave no trace of having been attempted.
 */
abstract contract ERC20TransferRestriction is ERC20ExtensionCore, IERC20TransferRestriction {
    /// @notice The transfer is allowed.
    uint8 public constant RESTRICTION_OK = 0;

    /// @notice All transfers are currently paused.
    uint8 public constant RESTRICTION_PAUSED = 1;

    /// @notice The sending account is frozen.
    uint8 public constant RESTRICTION_SENDER_FROZEN = 2;

    /// @notice The receiving account is frozen.
    uint8 public constant RESTRICTION_RECIPIENT_FROZEN = 3;

    bool private _paused;
    mapping(address account => bool frozen) private _frozen;

    function __ERC20TransferRestriction_init() internal onlyInitializing {
        _registerExtension(ExtensionIds.TRANSFER_RESTRICTION, BehaviorFlags.PAUSABLE | BehaviorFlags.BLOCKLIST);
    }

    // -----------------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20TransferRestriction
    function detectTransferRestriction(address from, address to, uint256) public view virtual returns (uint8) {
        if (_paused) return RESTRICTION_PAUSED;
        if (_frozen[from]) return RESTRICTION_SENDER_FROZEN;
        if (_frozen[to]) return RESTRICTION_RECIPIENT_FROZEN;
        return RESTRICTION_OK;
    }

    /// @inheritdoc IERC20TransferRestriction
    function messageForTransferRestriction(uint8 restrictionCode) public view virtual returns (string memory) {
        if (restrictionCode == RESTRICTION_OK) return "Transfer allowed";
        if (restrictionCode == RESTRICTION_PAUSED) return "Transfers are paused";
        if (restrictionCode == RESTRICTION_SENDER_FROZEN) return "Sender account is frozen";
        if (restrictionCode == RESTRICTION_RECIPIENT_FROZEN) return "Recipient account is frozen";
        return "Unknown restriction code";
    }

    /// @notice Whether all transfers are currently paused.
    function transfersPaused() public view virtual returns (bool) {
        return _paused;
    }

    /// @notice Whether `account` is frozen.
    function isFrozen(address account) public view virtual returns (bool) {
        return _frozen[account];
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

    /**
     * @notice Freezes or unfreezes one account.
     * @dev No {ExtensionConfigured} for this one: it is per-account rather than token-level, and duplicating
     *      each freeze into the generic event would double the log cost of every compliance action to carry
     *      what {AccountFrozen} already carried.
     */
    function setFrozen(address account, bool frozen) external virtual {
        _authorizeExtensionConfig(ExtensionIds.TRANSFER_RESTRICTION);

        _frozen[account] = frozen;

        emit AccountFrozen(account, frozen);
    }
}
