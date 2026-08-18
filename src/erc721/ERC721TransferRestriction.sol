// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC721ExtensionCore} from "./ERC721ExtensionCore.sol";

/**
 * @title ERC721TransferRestriction
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
 *      The same two asymmetries the fungible module makes, for the same reasons. A pause that also stopped
 *      minting and burning would brick the collection exactly when the authority most needs to intervene.
 *      And burning from a frozen account has to work, because freezing is what an issuer does *before*
 *      seizing — if the burn reverted, the freeze would have to be lifted first, which is the window the
 *      freeze exists to close. Minting *to* a frozen account stays rejected: crediting an account nobody
 *      may transact with is a mistake with no upside.
 *
 *      ## Why this composes with the operator policy rather than duplicating it
 *
 *      A freeze names an *account* and applies however the token moves. The operator policy names a
 *      *caller* and applies only when someone other than the owner is moving it. A collection can install
 *      both, and an integrator has to read both — which is why they are separate bits rather than one
 *      "restricted" flag that would tell nobody which question to ask.
 *
 * @custom:storage-location erc7201:berc.storage.ERC721TransferRestriction
 */
abstract contract ERC721TransferRestriction is ERC721ExtensionCore {
    /// @notice The transfer is allowed.
    uint8 public constant RESTRICTION_OK = 0;

    /// @notice All transfers are currently paused.
    uint8 public constant RESTRICTION_PAUSED = 1;

    /// @notice The sending account is frozen.
    uint8 public constant RESTRICTION_SENDER_FROZEN = 2;

    /// @notice The receiving account is frozen.
    uint8 public constant RESTRICTION_RECIPIENT_FROZEN = 3;

    /// @notice All transfers were paused, or one of the two accounts is frozen. See the code constants.
    error ERC721TransferRestricted(uint8 restrictionCode);

    /// @notice The zero address cannot be frozen; it is how mint and burn identify themselves.
    error ERC721InvalidFreezeTarget(address account);

    /// @notice The global pause was switched.
    event TransfersPaused(bool paused);

    /// @notice One account's freeze changed.
    event AccountFrozen(address indexed account, bool frozen);

    /// @custom:storage-location erc7201:berc.storage.ERC721TransferRestriction
    struct TransferRestrictionStorage {
        bool paused;
        mapping(address account => bool frozen) frozen;
    }

    // keccak256(abi.encode(uint256(keccak256("berc.storage.ERC721TransferRestriction")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC721_TRANSFER_RESTRICTION_STORAGE =
        0xb4ee2e589e7a7e4226fd7b91217e9506665c2f1979b8d918306167c9df468000;

    function _getTransferRestrictionStorage() private pure returns (TransferRestrictionStorage storage $) {
        assembly ("memory-safe") {
            $.slot := ERC721_TRANSFER_RESTRICTION_STORAGE
        }
    }

    function __ERC721TransferRestriction_init() internal onlyInitializing {
        _registerExtension(ExtensionIds.NFT_TRANSFER_RESTRICTION, BehaviorFlags.PAUSABLE | BehaviorFlags.BLOCKLIST);
    }

    // -----------------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------------

    /**
     * @notice Why a transfer would be rejected, or {RESTRICTION_OK}. ERC-1404's signature.
     * @dev Screen with this before submitting. It answers for the *accounts*; whether the caller is
     *      permitted to move a token it does not own is a separate question with a separate answer, in
     *      {ERC721OperatorRestriction-isOperatorAllowed}.
     */
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

    /// @notice A human-readable reason for a code from {detectTransferRestriction}. ERC-1404's signature.
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

    /// @inheritdoc ERC721ExtensionCore
    function _extensionData(bytes4 extensionId) internal view virtual override returns (bytes memory) {
        if (extensionId == ExtensionIds.NFT_TRANSFER_RESTRICTION) {
            return abi.encode(_getTransferRestrictionStorage().paused);
        }
        return super._extensionData(extensionId);
    }

    // -----------------------------------------------------------------------------------------------
    // Transfer pipeline — phase 1
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc ERC721ExtensionCore
    function _checkTransferAllowed(address from, address to, uint256 tokenId, address auth)
        internal
        view
        virtual
        override
    {
        if (_transferRestrictionActive()) {
            uint8 code = detectTransferRestriction(from, to, tokenId);
            if (code != RESTRICTION_OK) revert ERC721TransferRestricted(code);
        }
        super._checkTransferAllowed(from, to, tokenId, auth);
    }

    // -----------------------------------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------------------------------

    /// @notice Pauses or unpauses all transfers. Mint and burn are unaffected; see the table above.
    function setTransfersPaused(bool paused) external virtual {
        _authorizeExtensionConfig(ExtensionIds.NFT_TRANSFER_RESTRICTION);

        _getTransferRestrictionStorage().paused = paused;

        emit TransfersPaused(paused);
        _emitExtensionConfigured(ExtensionIds.NFT_TRANSFER_RESTRICTION);
    }

    /**
     * @notice Freezes or unfreezes one account.
     * @dev The zero address is rejected rather than stored, for the same reason the operator allowlist
     *      rejects it: it is how mint and burn identify themselves, so a freeze recorded against it could
     *      only ever be read as a value that means nothing.
     */
    function setFrozen(address account, bool frozen) external virtual {
        _authorizeExtensionConfig(ExtensionIds.NFT_TRANSFER_RESTRICTION);
        if (account == address(0)) revert ERC721InvalidFreezeTarget(account);

        _getTransferRestrictionStorage().frozen[account] = frozen;

        emit AccountFrozen(account, frozen);
    }

    /**
     * @dev Whether this module's checks apply. See the note on
     *      {ERC721OperatorRestriction-_operatorRestrictionActive}; the reasoning is identical.
     */
    function _transferRestrictionActive() internal view virtual returns (bool) {
        return true;
    }
}
