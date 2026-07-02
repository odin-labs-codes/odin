// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {IERC20Behavior} from "../interfaces/IERC20Behavior.sol";
import {IERC20Extensions} from "../interfaces/IERC20Extensions.sol";
import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";

/**
 * @title ERC20ExtensionCore
 * @notice The registry every extension module registers with, and the one place transfer phase order is
 *         decided.
 *
 * @dev Modules register themselves from their own initialiser, which is `onlyInitializing` and so can only
 *      run while the token is being constructed. Nothing can be added afterwards, which is what makes the
 *      set an integrator reads worth caching.
 *
 *      ## Why this contract owns `_update` alone
 *
 *      The obvious way to compose ERC-20 extensions is for each module to override `_update` and call
 *      `super._update`. It works, and it is a trap: the execution order then falls out of C3 linearisation,
 *      so `is Fee, Restriction` and `is Restriction, Fee` behave differently.
 *
 *      Here, `_update` is overridden exactly once, and modules override *phases* instead. The order is
 *      fixed in one readable function, a module cannot change it by being listed first, and each phase sees
 *      the arguments it was designed for.
 *
 *      Built on `ERC20Upgradeable` rather than `ERC20` so that one set of modules serves both an immutable
 *      token and a proxied one. The only thing that changes at runtime is which slot the balance mapping
 *      lives in; every function, event and revert an integrator can observe is identical.
 */
abstract contract ERC20ExtensionCore is Initializable, ERC20Upgradeable, IERC20Extensions, IERC20Behavior {
    bytes4[] private _extensionIds;
    mapping(bytes4 id => bool) private _extensionEnabled;
    uint256 private _behaviorFlags;
    bool private _extensionsSealed;

    /// @notice The same extension was registered twice.
    error ERC20ExtensionAlreadyRegistered(bytes4 extensionId);

    /// @notice The extension set was already sealed; registration is only possible during construction.
    error ERC20ExtensionSetSealed();

    /// @notice The token's discovery surface was read before the assembly called `_sealExtensions()`.
    error ERC20ExtensionSetNotSealed();

    /// @notice A behaviour bit outside `BehaviorFlags.ALL` was declared.
    error ERC20UnknownBehaviorFlag(uint256 flags);

    function __ERC20ExtensionCore_init() internal onlyInitializing {}

    // -----------------------------------------------------------------------------------------------
    // Transfer pipeline
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev The only `_update` override in the framework. Phase order is fixed here and is the same for
     *      every assembly regardless of the order modules are inherited in.
     *
     *      1. **Restriction checks.** First, because a transfer that is not allowed to happen must not have
     *         emitted a `Transfer` or called anything. Mint and burn reach this phase with a zero address
     *         intact, so a module can apply different rules to supply changes than it does to transfers.
     *
     *      2. **The transfer itself.**
     *
     *      3. **After-transfer work**, last and only once balances have settled, so a module reading state
     *         there cannot observe a half-applied transfer.
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        _checkTransferAllowed(from, to, value);
        super._update(from, to, value);
        _afterTransfer(from, to, value);
    }

    /**
     * @dev Phase 1. Revert to reject the transfer. Called for mint and burn too, with the zero address
     *      intact. Modules must call `super._checkTransferAllowed` so several can coexist.
     */
    function _checkTransferAllowed(address from, address to, uint256 value) internal view virtual {}

    /// @dev Phase 3. Runs after balances have settled. Modules must call `super._afterTransfer`.
    function _afterTransfer(address from, address to, uint256 value) internal virtual {}

    // -----------------------------------------------------------------------------------------------
    // Registration — construction only
    // -----------------------------------------------------------------------------------------------

    /// @dev Registers one extension and the behaviours it brings. Called from a module's initialiser.
    function _registerExtension(bytes4 extensionId, uint256 flags) internal onlyInitializing {
        if (_extensionsSealed) revert ERC20ExtensionSetSealed();
        if (_extensionEnabled[extensionId]) revert ERC20ExtensionAlreadyRegistered(extensionId);
        if (flags & ~BehaviorFlags.ALL != 0) revert ERC20UnknownBehaviorFlag(flags);

        _extensionEnabled[extensionId] = true;
        _extensionIds.push(extensionId);
        _behaviorFlags |= flags;
    }

    /**
     * @notice Freezes the extension set.
     * @dev **Every assembly must call this as the last step of its constructor or initialiser.** Until it
     *      does, {extensions}, {hasExtension} and {behaviorFlags} all revert, so an assembly that forgets has
     *      no discovery surface at all rather than a quietly incomplete one. Checking a flag on the transfer
     *      path instead would tax every transfer forever to catch a mistake that can only be made once, at
     *      deployment.
     */
    function _sealExtensions() internal onlyInitializing {
        if (_extensionsSealed) revert ERC20ExtensionSetSealed();
        _extensionsSealed = true;
    }

    /// @inheritdoc IERC20Extensions
    function extensions() public view virtual returns (bytes4[] memory) {
        _requireSealed();
        return _extensionIds;
    }

    /// @inheritdoc IERC20Extensions
    function hasExtension(bytes4 extensionId) public view virtual returns (bool) {
        _requireSealed();
        return _extensionEnabled[extensionId];
    }

    /// @inheritdoc IERC20Behavior
    function behaviorFlags() public view virtual returns (uint256) {
        _requireSealed();
        return _behaviorFlags;
    }

    function _requireSealed() private view {
        if (!_extensionsSealed) revert ERC20ExtensionSetNotSealed();
    }

    /**
     * @dev Every configuration entry point in every module routes through here, passing its own extension
     *      ID. An assembly implements this once and dispatches on the ID, which keeps per-extension
     *      authorities possible without any module having to know what access-control scheme is in use.
     *
     *      Left abstract on purpose: an assembly must state its authorisation policy rather than inherit a
     *      default that might be permissive.
     */
    function _authorizeExtensionConfig(bytes4 extensionId) internal view virtual;
}
