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
 * @dev ## Pause and freeze are transfer controls, not supply controls
 *
 *      | flow                     | paused    | sender frozen | recipient frozen |
 *      | ------------------------ | --------- | ------------- | ---------------- |
 *      | transfer (both non-zero) | rejected  | rejected      | rejected         |
 *      | mint (`from == 0`)       | allowed   | n/a           | rejected         |
 *      | burn (`to == 0`)         | allowed   | allowed       | n/a              |
 *
 *      Two deliberate asymmetries:
 *
 *      - **Pause does not stop mint or burn.** A pause is an emergency brake on circulation. If it also
 *        froze supply, the authority that pulled it would lose the ability to correct whatever caused it —
 *        the token would be bricked precisely when it most needs intervention.
 *      - **Burn works on a frozen account.** Freezing is what an issuer does before seizing; if a burn from
 *        a frozen account reverted, the freeze would have to be lifted first, which is exactly the window
 *        the freeze exists to close. Minting *to* a frozen account is still rejected, because crediting an
 *        account nobody may transact with is a mistake with no upside.
 *
 *      This module declares both `PAUSABLE` and `BLOCKLIST`, since it provides both.
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

    /// @custom:storage-location erc7201:berc.storage.TransferRestriction
    struct TransferRestrictionStorage {
        bool paused;
        mapping(address account => bool frozen) frozen;
    }

    // keccak256(abi.encode(uint256(keccak256("berc.storage.TransferRestriction")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TRANSFER_RESTRICTION_STORAGE =
        0x39f4fb228d5484c131c0e57f7df22064a0d89a65b73b5588d8e9c36b240edb00;

    function _getTransferRestrictionStorage() private pure returns (TransferRestrictionStorage storage $) {
        assembly ("memory-safe") {
            $.slot := TRANSFER_RESTRICTION_STORAGE
        }
    }

    function __ERC20TransferRestriction_init() internal onlyInitializing {
        _registerExtension(ExtensionIds.TRANSFER_RESTRICTION, BehaviorFlags.PAUSABLE | BehaviorFlags.BLOCKLIST);
    }

    // -----------------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20TransferRestriction
    function detectTransferRestriction(address from, address to, uint256) public view virtual returns (uint8) {
        TransferRestrictionStorage storage $ = _getTransferRestrictionStorage();

        if (from != address(0) && to != address(0)) {
            if ($.paused) return RESTRICTION_PAUSED;
            if ($.frozen[from]) return RESTRICTION_SENDER_FROZEN;
            if ($.frozen[to]) return RESTRICTION_RECIPIENT_FROZEN;
        } else if (from == address(0) && $.frozen[to]) {
            return RESTRICTION_RECIPIENT_FROZEN;
        }

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
        return _getTransferRestrictionStorage().paused;
    }

    /// @notice Whether `account` is frozen.
    function isFrozen(address account) public view virtual returns (bool) {
        return _getTransferRestrictionStorage().frozen[account];
    }

    /// @inheritdoc ERC20ExtensionCore
    function _extensionData(bytes4 extensionId) internal view virtual override returns (bytes memory) {
        if (extensionId == ExtensionIds.TRANSFER_RESTRICTION) {
            return abi.encode(_getTransferRestrictionStorage().paused);
        }
        return super._extensionData(extensionId);
    }

    /// @inheritdoc ERC20ExtensionCore
    function _accountFrozen(address account) internal view virtual override returns (bool) {
        return isFrozen(account);
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

    /// @notice Pauses or unpauses all transfers. Mint and burn are unaffected; see the table above.
    function setTransfersPaused(bool paused) external virtual {
        _authorizeExtensionConfig(ExtensionIds.TRANSFER_RESTRICTION);

        _getTransferRestrictionStorage().paused = paused;

        emit TransferPauseUpdated(paused);
        _emitExtensionConfigured(ExtensionIds.TRANSFER_RESTRICTION);
        _advanceConfigurationEpoch();
    }

    /// @notice Freezes or unfreezes one account.
    function setFrozen(address account, bool frozen) external virtual {
        _authorizeExtensionConfig(ExtensionIds.TRANSFER_RESTRICTION);

        _getTransferRestrictionStorage().frozen[account] = frozen;
        _touchAccountState(account);

        emit AccountFrozen(account, frozen);
        _advanceConfigurationEpoch();
    }
}
