// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {AccountState, IERC20AccountState} from "../interfaces/IERC20AccountState.sol";
import {IERC20Behavior} from "../interfaces/IERC20Behavior.sol";
import {IERC20CheckedTransfer} from "../interfaces/IERC20CheckedTransfer.sol";
import {IERC20Extensions} from "../interfaces/IERC20Extensions.sol";
import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";

/**
 * @title ERC20ExtensionCore
 * @notice The registry every extension module registers with, and the one place transfer phase order is
 *         decided.
 *
 * @dev Token-2022 gets its guarantees from a runtime: one program owns every mint, walks the account's TLV
 *      extensions in a fixed order, and no token author can change that order. The EVM has no such runtime,
 *      so the ordering has to be written down somewhere and enforced by construction. That somewhere is
 *      {_update} below.
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
 *      All state lives in an ERC-7201 namespace. That is required for the upgradeable variant and free for
 *      the immutable one, and it means a module can be mixed into a token in any position without its
 *      storage moving.
 *
 * @custom:storage-location erc7201:berc.storage.ExtensionRegistry
 */
abstract contract ERC20ExtensionCore is
    Initializable,
    ERC20Upgradeable,
    IERC20Extensions,
    IERC20Behavior,
    IERC20AccountState,
    IERC20CheckedTransfer
{
    /// @custom:storage-location erc7201:berc.storage.ExtensionRegistry
    struct ExtensionRegistryStorage {
        bytes4[] ids;
        mapping(bytes4 id => bool) enabled;
        uint256 behaviorFlags;
        bool isSealed;
        mapping(address account => uint64 timestamp) configuredAt;
        uint64 configurationEpoch;
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

    /// @notice The declared behaviours contradict each other. See `BehaviorFlags.conflictingPair`.
    error ERC20IncompatibleBehaviors(uint256 first, uint256 second);

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
    // Checked transfers
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20CheckedTransfer
    function configurationEpoch() public view virtual returns (uint64) {
        return _getExtensionRegistryStorage().configurationEpoch;
    }

    /// @inheritdoc IERC20CheckedTransfer
    function transferChecked(address to, uint256 amount, uint256 minAmountReceived, uint64 expectedConfigurationEpoch)
        public
        virtual
        returns (uint256 received)
    {
        _requireConfigurationEpoch(expectedConfigurationEpoch);
        received = _measuredTransfer(_msgSender(), to, amount);
        if (received < minAmountReceived) {
            revert ERC20CheckedTransferUnderMinimum(received, minAmountReceived);
        }
    }

    /// @inheritdoc IERC20CheckedTransfer
    function transferFromChecked(
        address from,
        address to,
        uint256 amount,
        uint256 minAmountReceived,
        uint64 expectedConfigurationEpoch
    ) public virtual returns (uint256 received) {
        _requireConfigurationEpoch(expectedConfigurationEpoch);
        _spendAllowance(from, _msgSender(), amount);
        received = _measuredTransfer(from, to, amount);
        if (received < minAmountReceived) {
            revert ERC20CheckedTransferUnderMinimum(received, minAmountReceived);
        }
    }

    /**
     * @dev Runs the transfer and reports what `to` actually gained, by reading its balance either side of
     *      the call rather than asking any module to predict it. Measurement is what makes the guarantee
     *      hold for combinations nobody enumerated: whatever the installed extensions do between these two
     *      reads, the number returned is the number that landed.
     *
     *      A sender transferring to itself sees its balance fall by the fee, never rise, so the increase is
     *      clamped at zero instead of underflowing into a panic. Zero is the honest answer — nothing
     *      arrived that was not already there.
     */
    function _measuredTransfer(address from, address to, uint256 amount) private returns (uint256) {
        uint256 balanceBefore = balanceOf(to);
        _transfer(from, to, amount);
        uint256 balanceAfter = balanceOf(to);
        return balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
    }

    /// @dev Shared with any module offering a checked entry point of its own, such as the fee module's
    ///      exact-output pair.
    function _requireConfigurationEpoch(uint64 expected) internal view {
        if (expected == 0) return;
        uint64 actual = _getExtensionRegistryStorage().configurationEpoch;
        if (expected != actual) revert ERC20CheckedTransferEpochMismatch(expected, actual);
    }

    // -----------------------------------------------------------------------------------------------
    // Registration — construction only
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev Registers one extension and the behaviours it brings. Called from a module's initialiser, so it
     *      can only run while the token is being constructed or initialised.
     */
    function _registerExtension(bytes4 extensionId, uint256 flags) internal onlyInitializing {
        ExtensionRegistryStorage storage $ = _getExtensionRegistryStorage();
        if ($.isSealed) revert ERC20ExtensionSetSealed();
        if ($.enabled[extensionId]) revert ERC20ExtensionAlreadyRegistered(extensionId);

        $.enabled[extensionId] = true;
        $.ids.push(extensionId);
        _declareBehavior(flags);
    }

    /**
     * @dev Declares behaviour that is not tied to an extension module. `UPGRADEABLE` is the case this
     *      exists for: it is a property of how the token is deployed, not of anything it inherits.
     */
    function _declareBehavior(uint256 flags) internal onlyInitializing {
        if (flags & ~BehaviorFlags.ALL != 0) revert ERC20UnknownBehaviorFlag(flags);
        ExtensionRegistryStorage storage $ = _getExtensionRegistryStorage();
        if ($.isSealed) revert ERC20ExtensionSetSealed();
        $.behaviorFlags |= flags;
    }

    /**
     * @notice Freezes the extension set and validates that the declared behaviours are consistent.
     * @dev **Every assembly must call this as the last step of its constructor or initialiser.** Until it
     *      does, {extensions}, {hasExtension}, {extensionData} and {behaviorFlags} all revert, so an
     *      assembly that forgets has no discovery surface at all rather than a quietly unvalidated one.
     *      Checking a flag on the transfer path instead would tax every transfer forever to catch a mistake
     *      that can only be made once, at deployment.
     */
    function _sealExtensions() internal onlyInitializing {
        ExtensionRegistryStorage storage $ = _getExtensionRegistryStorage();
        if ($.isSealed) revert ERC20ExtensionSetSealed();

        (uint256 first, uint256 second) = BehaviorFlags.conflictingPair($.behaviorFlags);
        if (first != 0) revert ERC20IncompatibleBehaviors(first, second);

        $.isSealed = true;
        // Every assembly is required to reach here, which makes it the one place guaranteed to run exactly
        // once per token — so it is where the epoch starts. Starting at 1 rather than 0 is what lets
        // `expectedConfigurationEpoch == 0` mean "not checking" instead of colliding with a real epoch.
        $.configurationEpoch = 1;
    }

    /**
     * @dev Called by every configuration change that could alter what a transfer does. Deliberately not
     *      wired into `_authorizeExtensionConfig` or `_emitExtensionConfigured`, which would have made it
     *      automatic: metadata changes route through both of those and must *not* advance the epoch, since
     *      bricking a treasury's pending checked transfer because the token updated its logo URI is exactly
     *      the failure mode that makes callers stop using the epoch at all.
     */
    function _advanceConfigurationEpoch() internal {
        ExtensionRegistryStorage storage $ = _getExtensionRegistryStorage();
        // Checked arithmetic on purpose. Wrapping is unreachable in practice, but the value it would wrap
        // to is `0`, which is the "do not check" sentinel — the one number this counter must never return.
        uint64 next = $.configurationEpoch + 1;
        $.configurationEpoch = next;
        emit ConfigurationEpochAdvanced(next);
    }

    /// @dev Records that per-account extension state changed, for {accountState}.
    function _touchAccountState(address account) internal {
        _getExtensionRegistryStorage().configuredAt[account] = uint64(block.timestamp);
    }

    /// @dev Emits {ExtensionConfigured} carrying the extension's full configuration after the change.
    function _emitExtensionConfigured(bytes4 extensionId) internal {
        emit ExtensionConfigured(extensionId, extensionData(extensionId));
    }

    /**
     * @dev Every configuration entry point in every module routes through here, passing its own extension
     *      ID. An assembly implements this once and dispatches on the ID, which keeps per-extension
     *      authorities — Token-2022's model, where the fee authority and the freeze authority are different
     *      keys — without any module having to know what access-control scheme is in use.
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

    /// @inheritdoc IERC20AccountState
    function accountState(address account) public view virtual returns (AccountState memory) {
        return AccountState({
            frozen: _accountFrozen(account),
            feeExempt: _accountFeeExempt(account),
            configuredAt: _getExtensionRegistryStorage().configuredAt[account]
        });
    }

    /// @dev Overridden by the restriction module. Neutral value when that module is not installed.
    function _accountFrozen(address) internal view virtual returns (bool) {
        return false;
    }

    /// @dev Overridden by the fee module. Neutral value when that module is not installed.
    function _accountFeeExempt(address) internal view virtual returns (bool) {
        return false;
    }

    function _sealedStorage() private view returns (ExtensionRegistryStorage storage $) {
        $ = _getExtensionRegistryStorage();
        if (!$.isSealed) revert ERC20ExtensionSetNotSealed();
    }
}
