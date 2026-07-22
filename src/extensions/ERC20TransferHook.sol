// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20TransferHook, ITransferHookReceiver} from "../interfaces/IERC20TransferHook.sol";
import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC20ExtensionCore} from "./ERC20ExtensionCore.sol";

/**
 * @title ERC20TransferHook
 * @notice Calls a policy contract after every transfer, under a gas bound.
 *
 * @dev A transfer hook is the single most expensive thing this framework lets a token do to the people
 *      integrating with it, so it is built to be *survivable* rather than flexible:
 *
 *      - **Last.** The hook runs in phase 4, after balances have settled. It can never observe a
 *        half-applied transfer, and it cannot influence the amounts — only accept or reject the result.
 *      - **Bounded.** The hook gets exactly {transferHookGasLimit} gas, published so integrators can budget
 *        a worst case instead of discovering it. The EVM withholds 1/64 of the remaining gas from any call,
 *        so a caller must actually hold slightly more than this for the hook to receive its full budget.
 *      - **Strict.** A reverting hook reverts the transfer, and a hook that does not return its
 *        acknowledgement selector reverts it too. Swallowing hook failures would turn a policy contract
 *        into decoration, and the `TRANSFER_HOOK` flag exists precisely to warn that transfers can fail for
 *        reasons unrelated to balances.
 *
 *      Mint and burn do not fire the hook; phase 4 only runs for transfers between two real accounts.
 */
abstract contract ERC20TransferHook is ERC20ExtensionCore, IERC20TransferHook {
    /// @notice Floor on the configurable gas limit. Below this a hook cannot do anything useful.
    uint32 public constant MIN_HOOK_GAS_LIMIT = 30_000;

    /// @notice Ceiling on the configurable gas limit, so the declared worst case stays a real bound.
    uint32 public constant MAX_HOOK_GAS_LIMIT = 1_000_000;

    address private _hook;
    uint32 private _gasLimit;

    function __ERC20TransferHook_init() internal onlyInitializing {
        _registerExtension(ExtensionIds.TRANSFER_HOOK, BehaviorFlags.TRANSFER_HOOK);
    }

    // -----------------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20TransferHook
    function transferHook() public view virtual returns (address) {
        return _hook;
    }

    /// @inheritdoc IERC20TransferHook
    function transferHookGasLimit() public view virtual returns (uint32) {
        return _gasLimit;
    }

    /// @inheritdoc ERC20ExtensionCore
    function _extensionData(bytes4 extensionId) internal view virtual override returns (bytes memory) {
        if (extensionId == ExtensionIds.TRANSFER_HOOK) {
            return abi.encode(_hook, _gasLimit);
        }
        return super._extensionData(extensionId);
    }

    // -----------------------------------------------------------------------------------------------
    // Transfer pipeline — phase 4
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc ERC20ExtensionCore
    function _afterTransfer(address from, address to, uint256 value) internal virtual override {
        super._afterTransfer(from, to, value);

        address hook = _hook;
        if (hook == address(0)) return;

        try ITransferHookReceiver(hook).onTransfer{gas: _gasLimit}(address(this), from, to, value) returns (
            bytes4 acknowledgement
        ) {
            if (acknowledgement != ITransferHookReceiver.onTransfer.selector) {
                revert ERC20TransferHookNotAcknowledged(hook);
            }
        } catch (bytes memory reason) {
            revert ERC20TransferHookFailed(reason);
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

        if (hook == address(0)) gasLimit = 0;

        _hook = hook;
        _gasLimit = gasLimit;

        emit TransferHookUpdated(hook, gasLimit);
        _emitExtensionConfigured(ExtensionIds.TRANSFER_HOOK);
    }
}
