// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {IERC20Behavior} from "../interfaces/IERC20Behavior.sol";
import {IERC20Extensions} from "../interfaces/IERC20Extensions.sol";
import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";

/**
 * @title ERC20ExtensionCore
 * @notice The registry every extension module registers with.
 *
 * @dev Modules register themselves from their own initialiser, which is `onlyInitializing` and so can only
 *      run while the token is being constructed. Nothing can be added afterwards, which is what makes the
 *      set an integrator reads worth caching.
 *
 *      Built on `ERC20Upgradeable` rather than `ERC20` so that one set of modules serves both an immutable
 *      token and a proxied one. The only thing that changes at runtime is which slot the balance mapping
 *      lives in; every function, event and revert an integrator can observe is identical.
 */
abstract contract ERC20ExtensionCore is Initializable, ERC20Upgradeable, IERC20Extensions, IERC20Behavior {
    bytes4[] private _extensionIds;
    mapping(bytes4 id => bool) private _extensionEnabled;
    uint256 private _behaviorFlags;

    /// @notice The same extension was registered twice.
    error ERC20ExtensionAlreadyRegistered(bytes4 extensionId);

    /// @notice A behaviour bit outside `BehaviorFlags.ALL` was declared.
    error ERC20UnknownBehaviorFlag(uint256 flags);

    function __ERC20ExtensionCore_init() internal onlyInitializing {}

    /// @dev Registers one extension and the behaviours it brings. Called from a module's initialiser.
    function _registerExtension(bytes4 extensionId, uint256 flags) internal onlyInitializing {
        if (_extensionEnabled[extensionId]) revert ERC20ExtensionAlreadyRegistered(extensionId);
        if (flags & ~BehaviorFlags.ALL != 0) revert ERC20UnknownBehaviorFlag(flags);

        _extensionEnabled[extensionId] = true;
        _extensionIds.push(extensionId);
        _behaviorFlags |= flags;
    }

    /// @inheritdoc IERC20Extensions
    function extensions() public view virtual returns (bytes4[] memory) {
        return _extensionIds;
    }

    /// @inheritdoc IERC20Extensions
    function hasExtension(bytes4 extensionId) public view virtual returns (bool) {
        return _extensionEnabled[extensionId];
    }

    /// @inheritdoc IERC20Behavior
    function behaviorFlags() public view virtual returns (uint256) {
        return _behaviorFlags;
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
