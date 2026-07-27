// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {IERC20TransferHook, ITransferHookReceiver} from "../interfaces/IERC20TransferHook.sol";
import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC20ExtensionCore} from "./ERC20ExtensionCore.sol";

/**
 * @title ERC20TransferHook
 * @notice Calls a policy contract after every transfer, under a gas bound and a reentrancy guard.
 *
 * @dev A transfer hook is the single most expensive thing this framework lets a token do to the people
 *      integrating with it, so it is built to be *survivable* rather than flexible:
 *
 *      - **Last.** The hook runs in phase 4, after balances have settled. It can never observe a
 *        half-applied transfer, and it cannot influence the amounts — only accept or reject the result.
 *      - **Guarded.** {_update} is wrapped in a transient-storage reentrancy guard, so a hook that calls
 *        back into any balance-moving path on this token reverts. The guard lives in this module rather
 *        than in `ERC20ExtensionCore` so that an assembly built without this module pays nothing for it; a
 *        token with no external calls on its transfer path has no reentrancy to guard against.
 *      - **Bounded.** The hook gets exactly {transferHookGasLimit} gas, published so integrators can budget
 *        a worst case instead of discovering it. The EVM withholds 1/64 of the remaining gas from any call,
 *        so a caller must actually hold slightly more than this for the hook to receive its full budget.
 *      - **Strict.** A reverting hook reverts the transfer, and a hook that does not return its
 *        acknowledgement selector reverts it too. Swallowing hook failures would turn a policy contract
 *        into decoration, and the `TRANSFER_HOOK` flag exists precisely to warn that transfers can fail for
 *        reasons unrelated to balances.
 *
 *      Mint and burn do not fire the hook; phase 4 only runs for transfers between two real accounts.
 *
 * @custom:storage-location erc7201:berc.storage.TransferHook
 */
abstract contract ERC20TransferHook is ERC20ExtensionCore, ReentrancyGuardTransientUpgradeable, IERC20TransferHook {
    /// @notice Floor on the configurable gas limit. Below this a hook cannot do anything useful.
    uint32 public constant MIN_HOOK_GAS_LIMIT = 30_000;

    /// @notice Ceiling on the configurable gas limit, so the declared worst case stays a real bound.
    uint32 public constant MAX_HOOK_GAS_LIMIT = 1_000_000;

    /// @dev The acknowledgement is one selector in one word. Nothing longer is ever read.
    uint256 private constant HOOK_RETURNDATA_LIMIT = 32;

    /// @dev How much of a reverting hook's reason is carried into {ERC20TransferHookFailed}.
    uint256 private constant HOOK_REVERT_REASON_LIMIT = 256;

    /// @custom:storage-location erc7201:berc.storage.TransferHook
    struct TransferHookStorage {
        address hook;
        uint32 gasLimit;
    }

    // keccak256(abi.encode(uint256(keccak256("berc.storage.TransferHook")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TRANSFER_HOOK_STORAGE =
        0x234bd1b5f25fbf979510559c69ff089ee9e0b4d5f6176dc1aa6c3b20cf6fb400;

    function _getTransferHookStorage() private pure returns (TransferHookStorage storage $) {
        assembly ("memory-safe") {
            $.slot := TRANSFER_HOOK_STORAGE
        }
    }

    function __ERC20TransferHook_init() internal onlyInitializing {
        __ReentrancyGuardTransient_init();
        _registerExtension(ExtensionIds.TRANSFER_HOOK, BehaviorFlags.TRANSFER_HOOK);
    }

    // -----------------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20TransferHook
    function transferHook() public view virtual returns (address) {
        return _getTransferHookStorage().hook;
    }

    /// @inheritdoc IERC20TransferHook
    function transferHookGasLimit() public view virtual returns (uint32) {
        return _getTransferHookStorage().gasLimit;
    }

    /// @inheritdoc ERC20ExtensionCore
    function _extensionData(bytes4 extensionId) internal view virtual override returns (bytes memory) {
        if (extensionId == ExtensionIds.TRANSFER_HOOK) {
            TransferHookStorage storage $ = _getTransferHookStorage();
            return abi.encode($.hook, $.gasLimit);
        }
        return super._extensionData(extensionId);
    }

    // -----------------------------------------------------------------------------------------------
    // Transfer pipeline — the guard, and phase 4
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev Wraps the whole pipeline so the guard is already held when the hook runs in phase 4. The fee
     *      module's internal leg goes through `_rawUpdate`, which reaches `ERC20Upgradeable._update`
     *      directly and never re-enters this function, so splitting a transfer in two does not trip the
     *      guard on itself.
     */
    function _update(address from, address to, uint256 value) internal virtual override nonReentrant {
        super._update(from, to, value);
    }

    /**
     * @inheritdoc ERC20ExtensionCore
     * @dev The call is written in assembly for one reason: a high-level call assigns the callee's return
     *      data into `bytes memory`, and that `RETURNDATACOPY` plus its memory expansion is paid by *this*
     *      contract, out of the caller's gas, after the hook's own budget has already been released.
     *
     *      That turns the published gas bound into a fiction. A hook given 1,000,000 gas can spend most of
     *      it expanding its own memory and return several hundred kilobytes; copying that back here costs
     *      roughly as much again, so an integrator who budgeted `transferHookGasLimit()` — exactly what
     *      this framework tells them to budget — runs out of gas through no fault of their own.
     *
     *      So the return data is never copied wholesale. The acknowledgement is one word and is read only
     *      when the hook returned exactly one word; a revert reason is truncated to a prefix long enough to
     *      stay useful. Both costs are now constant, and `transferHookGasLimit()` bounds the hook again.
     */
    function _afterTransfer(address from, address to, uint256 value) internal virtual override {
        super._afterTransfer(from, to, value);

        TransferHookStorage storage $ = _getTransferHookStorage();
        address hook = $.hook;
        if (hook == address(0)) return;

        bytes memory payload = abi.encodeCall(ITransferHookReceiver.onTransfer, (address(this), from, to, value));
        uint256 gasLimit = $.gasLimit;

        bool success;
        uint256 returnedSize;
        bytes32 acknowledgement;
        bytes memory reason;

        assembly ("memory-safe") {
            success := call(gasLimit, hook, 0, add(payload, 0x20), mload(payload), 0x00, 0x00)
            returnedSize := returndatasize()

            switch success
            case 0 {
                let size := returnedSize
                if gt(size, HOOK_REVERT_REASON_LIMIT) { size := HOOK_REVERT_REASON_LIMIT }
                reason := mload(0x40)
                mstore(reason, size)
                returndatacopy(add(reason, 0x20), 0x00, size)
                mstore(0x40, add(add(reason, 0x20), and(add(size, 0x1f), not(0x1f))))
            }
            default {
                // Reading only at the exact expected width keeps the scratch slot from carrying stale
                // bytes into the comparison below.
                if eq(returnedSize, HOOK_RETURNDATA_LIMIT) {
                    returndatacopy(0x00, 0x00, HOOK_RETURNDATA_LIMIT)
                    acknowledgement := mload(0x00)
                }
            }
        }

        if (!success) revert ERC20TransferHookFailed(reason);

        // Discarding the low-order 28 bytes is the point, not a hazard: `bytes4(bytes32)` keeps the
        // high-order four, which is where the ABI puts a `bytes4` return value in its word — the same
        // bytes `abi.decode(..., (bytes4))` would have read.
        bytes4 selector = bytes4(acknowledgement);
        if (returnedSize != HOOK_RETURNDATA_LIMIT || selector != ITransferHookReceiver.onTransfer.selector) {
            revert ERC20TransferHookNotAcknowledged(hook);
        }
    }

    // -----------------------------------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------------------------------

    /**
     * @notice Installs, replaces, or removes the transfer hook.
     * @dev Pass `address(0)` to remove it; `gasLimit` is then forced to zero so
     *      {transferHookGasLimit} never advertises a budget for a hook that will not be called.
     */
    function setTransferHook(address hook, uint32 gasLimit) external virtual {
        _authorizeExtensionConfig(ExtensionIds.TRANSFER_HOOK);

        if (hook == address(0)) {
            gasLimit = 0;
        } else {
            // An EOA would return empty returndata and silently fail the acknowledgement check on every
            // transfer, bricking the token. Catching it here turns that into a failed configuration call.
            if (hook.code.length == 0) revert ERC20InvalidTransferHook(hook);
            if (gasLimit < MIN_HOOK_GAS_LIMIT || gasLimit > MAX_HOOK_GAS_LIMIT) {
                revert ERC20InvalidHookGasLimit(gasLimit, MIN_HOOK_GAS_LIMIT, MAX_HOOK_GAS_LIMIT);
            }
        }

        TransferHookStorage storage $ = _getTransferHookStorage();
        $.hook = hook;
        $.gasLimit = gasLimit;

        emit TransferHookUpdated(hook, gasLimit);
        _emitExtensionConfigured(ExtensionIds.TRANSFER_HOOK);
    }
}
