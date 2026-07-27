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
 *      so `is Fee, Restriction` and `is Restriction, Fee` behave differently. Worse, a module that splits a
 *      transfer into two `super._update` calls — which any fee module must — sends both halves back through
 *      every module below it, so a restriction module ends up screening the fee leg as if it were a user
 *      transfer, against the fee vault's address and the fee's amount.
 *
 *      Here, `_update` is overridden exactly once, and modules override *phases* instead. The order is
 *      fixed in one readable function, a module cannot change it by being listed first, and each phase sees
 *      the arguments it was designed for.
 *
 *      ## Storage
 *
 *      All state lives in an ERC-7201 namespace. That is required for a proxied variant and free for the
 *      immutable one, and it means a module can be mixed into a token in any position without its storage
 *      moving.
 *
 * @custom:storage-location erc7201:berc.storage.ExtensionRegistry
 */
abstract contract ERC20ExtensionCore is Initializable, ERC20Upgradeable, IERC20Extensions, IERC20Behavior {
    /// @custom:storage-location erc7201:berc.storage.ExtensionRegistry
    struct ExtensionRegistryStorage {
        bytes4[] ids;
        mapping(bytes4 id => bool) enabled;
        uint256 behaviorFlags;
        bool isSealed;
    }

    // keccak256(abi.encode(uint256(keccak256("berc.storage.ExtensionRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EXTENSION_REGISTRY_STORAGE =
        0x73de07cf09e3d27a660e4065029788fb1c84a63adfe4aa03b3627cfea2944900;

    /// @notice The same extension was registered twice.
    error ERC20ExtensionAlreadyRegistered(bytes4 extensionId);

    /// @notice The extension set was already sealed; registration is only possible during construction.
    error ERC20ExtensionSetSealed();

    /// @notice The token's discovery surface was read before the assembly called `_sealExtensions()`.
    error ERC20ExtensionSetNotSealed();

    /// @notice A behaviour bit outside `BehaviorFlags.ALL` was declared.
    error ERC20UnknownBehaviorFlag(uint256 flags);

    /// @notice A fee module returned a fee larger than the amount being transferred.
    error ERC20FeeExceedsAmount(uint256 fee, uint256 amount);

    function _getExtensionRegistryStorage() private pure returns (ExtensionRegistryStorage storage $) {
        assembly ("memory-safe") {
            $.slot := EXTENSION_REGISTRY_STORAGE
        }
    }

    function __ERC20ExtensionCore_init() internal onlyInitializing {}

    // -----------------------------------------------------------------------------------------------
    // Transfer pipeline
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev The only `_update` override in the framework. Phase order is fixed here and is the same for
     *      every assembly regardless of the order modules are inherited in.
     *
     *      1. **Restriction checks.** First, because a transfer that is not allowed to happen must not have
     *         moved a fee, emitted a `Transfer`, or called anything. Mint and burn reach this phase with a
     *         zero address intact, so a module can apply different rules to supply changes than it does to
     *         transfers.
     *
     *      2. **Fee collection**, as a separate `_rawUpdate` from the sender to the vault. Separate because
     *         the fee is a real movement of value between two real accounts and deserves its own `Transfer`
     *         event; an indexer that only saw the net leg would show a supply leak. It runs before the main
     *         leg so that a sender holding exactly `value` succeeds: the two legs debit `fee` and
     *         `value - fee`, which is `value` in total, and either order fits the balance. It is skipped
     *         entirely for mint and burn — a fee on minting invents supply, a fee on burning is not a burn.
     *
     *      3. **The transfer itself**, for `value - fee`.
     *
     *      4. **The hook**, last and only after balances have settled, so the hook observes a consistent
     *         state and cannot be used to observe a half-applied transfer. `ERC20TransferHook` additionally
     *         wraps this whole function in a reentrancy guard; see that contract for why the guard belongs
     *         there and not here.
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        _checkTransferAllowed(from, to, value);

        // A zero address on either side means supply is being created or destroyed, not moved.
        bool isTransfer = from != address(0) && to != address(0);

        uint256 fee = 0;
        if (isTransfer) {
            fee = _collectTransferFee(from, to, value);
            // A module is free to compute any fee it likes, but not one that would underflow the main leg.
            if (fee > value) revert ERC20FeeExceedsAmount(fee, value);
        }

        uint256 net = value - fee;
        super._update(from, to, net);

        if (isTransfer) {
            _afterTransfer(from, to, net);
        }
    }

    /**
     * @dev Moves `value` without running any extension phase. The fee module uses this for the fee leg;
     *      routing that leg back through {_update} would re-run every check against the wrong arguments and
     *      recurse. Nothing else should ever call it.
     */
    function _rawUpdate(address from, address to, uint256 value) internal {
        super._update(from, to, value);
    }

    /**
     * @dev Phase 1. Revert to reject the transfer. Called for mint and burn too, with the zero address
     *      intact. Modules must call `super._checkTransferAllowed` so several can coexist.
     */
    function _checkTransferAllowed(address from, address to, uint256 value) internal view virtual {}

    /**
     * @dev Phase 2. Return the amount to withhold from `value` and move it to wherever it belongs, using
     *      {_rawUpdate}. Never called for mint or burn. Modules must call `super._collectTransferFee` and
     *      add to its result.
     *
     *      The base case charges nothing and so names none of `(from, to, value)`; the fee module's
     *      override declares them.
     */
    function _collectTransferFee(address, address, uint256) internal virtual returns (uint256) {
        return 0;
    }

    /**
     * @dev Phase 4. Runs after balances have settled, with `value` being the amount actually credited to
     *      `to`. Never called for mint or burn. Modules must call `super._afterTransfer`.
     */
    function _afterTransfer(address from, address to, uint256 value) internal virtual {}

    // -----------------------------------------------------------------------------------------------
    // Registration — construction only
    // -----------------------------------------------------------------------------------------------

    /// @dev Registers one extension and the behaviours it brings. Called from a module's initialiser.
    function _registerExtension(bytes4 extensionId, uint256 flags) internal onlyInitializing {
        ExtensionRegistryStorage storage $ = _getExtensionRegistryStorage();
        if ($.isSealed) revert ERC20ExtensionSetSealed();
        if ($.enabled[extensionId]) revert ERC20ExtensionAlreadyRegistered(extensionId);
        if (flags & ~BehaviorFlags.ALL != 0) revert ERC20UnknownBehaviorFlag(flags);

        $.enabled[extensionId] = true;
        $.ids.push(extensionId);
        $.behaviorFlags |= flags;
    }

    /**
     * @notice Freezes the extension set.
     * @dev **Every assembly must call this as the last step of its constructor or initialiser.** Until it
     *      does, {extensions}, {hasExtension}, {extensionData} and {behaviorFlags} all revert, so an
     *      assembly that forgets has no discovery surface at all rather than a quietly incomplete one.
     *      Checking a flag on the transfer path instead would tax every transfer forever to catch a mistake
     *      that can only be made once, at deployment.
     */
    function _sealExtensions() internal onlyInitializing {
        ExtensionRegistryStorage storage $ = _getExtensionRegistryStorage();
        if ($.isSealed) revert ERC20ExtensionSetSealed();
        $.isSealed = true;
    }

    /// @dev Emits {ExtensionConfigured} carrying the extension's full configuration after the change.
    function _emitExtensionConfigured(bytes4 extensionId) internal {
        emit ExtensionConfigured(extensionId, extensionData(extensionId));
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

    // -----------------------------------------------------------------------------------------------
    // Discovery
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20Extensions
    function extensions() public view virtual returns (bytes4[] memory) {
        return _sealedStorage().ids;
    }

    /// @inheritdoc IERC20Extensions
    function hasExtension(bytes4 extensionId) public view virtual returns (bool) {
        return _sealedStorage().enabled[extensionId];
    }

    /**
     * @inheritdoc IERC20Extensions
     * @dev Deliberately not `virtual`. The seal check and the not-installed check belong to every call, and
     *      a module overriding the public function would answer for its own ID before either one ran —
     *      which is exactly how a token with an unsealed registry could still look configured. Modules
     *      extend {_extensionData} instead, which this reaches only after both checks have passed.
     */
    function extensionData(bytes4 extensionId) public view returns (bytes memory) {
        if (!_sealedStorage().enabled[extensionId]) revert ERC20ExtensionNotEnabled(extensionId);
        return _extensionData(extensionId);
    }

    /**
     * @dev Modules override this to return their own configuration and delegate everything else upward.
     *      Reaching the base case means the ID belongs to an installed module that has nothing to report,
     *      so empty bytes is the right answer — "installed but unconfigured" stays distinguishable from
     *      "not installed", which reverts one level up.
     */
    function _extensionData(bytes4) internal view virtual returns (bytes memory) {
        return "";
    }

    /// @inheritdoc IERC20Behavior
    function behaviorFlags() public view virtual returns (uint256) {
        return _sealedStorage().behaviorFlags;
    }

    function _sealedStorage() private view returns (ExtensionRegistryStorage storage $) {
        $ = _getExtensionRegistryStorage();
        if (!$.isSealed) revert ERC20ExtensionSetNotSealed();
    }
}
