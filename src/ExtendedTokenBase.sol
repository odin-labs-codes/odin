// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BERCAccessControl} from "./access/BERCAccessControl.sol";
import {ERC20ExtensionCore} from "./extensions/ERC20ExtensionCore.sol";
import {ERC20OnchainMetadata} from "./extensions/ERC20OnchainMetadata.sol";
import {ERC20TransferFee} from "./extensions/ERC20TransferFee.sol";
import {ERC20TransferHook} from "./extensions/ERC20TransferHook.sol";
import {ERC20TransferRestriction} from "./extensions/ERC20TransferRestriction.sol";
import {BehaviorFlags} from "./libraries/BehaviorFlags.sol";
import {ExtensionIds} from "./libraries/ExtensionIds.sol";

/**
 * @title ExtendedTokenBase
 * @notice The shared assembly behind both reference tokens: four extension modules, one role per authority,
 *         and nothing else.
 *
 * @dev ## What is assembled here
 *
 *      Metadata, transfer fee, transfer restriction and transfer hook. `ERC20NonTransferable` is absent by
 *      necessity, not oversight: `NON_TRANSFERABLE` contradicts both `FEE_ON_TRANSFER` and `TRANSFER_HOOK`,
 *      so an assembly containing all five would revert in its own constructor. The module is exercised by
 *      the combination-matrix tests, which assemble it against every other subset.
 *
 *      The order the modules are listed in below does not affect behaviour — `ERC20ExtensionCore` owns the
 *      only `_update` and fixes the phase order there. This is a property worth relying on: a third party
 *      assembling their own token cannot get the ordering wrong by listing modules in the order that reads
 *      best.
 *
 *      ## One role per authority — and what that is not
 *
 *      Each extension has its own role, reached through the single {_authorizeExtensionConfig} dispatch
 *      that every module's setters route into. The modules themselves know nothing about roles, so a
 *      different assembly can swap in `Ownable`, a timelock, or a governor without touching them.
 *
 *      This resembles Token-2022's separate authorities and is **not** equivalent to them, which matters
 *      enough to state plainly rather than let an integrator infer:
 *
 *      - **`DEFAULT_ADMIN_ROLE` can grant itself any of the others until administration is burned.** These
 *        begin as operational roles under a replaceable admin, not independent authorities. Splitting the
 *        keys limits blast radius for an operator mistake or a single compromised key; it does not bound
 *        what the token's admin can do before {burnAdminPrivileges}. After that one-way call, grants and
 *        forced revocations are disabled globally and each authority may renounce permanently.
 *      - **`SEIZE_ROLE` takes balances, and separating it from `MINT_ROLE` does not make that safe.** The
 *        two are split because they are genuinely different powers and `behaviorFlags()` declares them
 *        separately — a vocabulary finer-grained than the authorities behind it is a vocabulary that
 *        misleads. What the split buys is blast radius: a compromised minting key cannot empty accounts,
 *        and a compliance key that settles frozen balances cannot dilute holders. What it does not buy is
 *        any bound on the admin, which can still grant itself both.
 *      - **Role holders are not enumerable on chain.** `AccessControl` answers `hasRole(role, account)`
 *        but cannot list holders, so an integrator auditing who holds what has to reconstruct it from
 *        `RoleGranted` and `RoleRevoked` logs.
 *
 *      The initialiser grants every role to `admin` so that a deployment is usable immediately. Splitting
 *      them across separate keys is the expected next step and is what `script/Deploy.s.sol` demonstrates,
 *      including the postcondition checks that prove the split actually landed.
 */
abstract contract ExtendedTokenBase is
    ERC20OnchainMetadata,
    ERC20TransferFee,
    ERC20TransferRestriction,
    ERC20TransferHook,
    BERCAccessControl
{
    /// @notice Creates supply. The power `BehaviorFlags.MINTABLE` declares.
    bytes32 public constant MINT_ROLE = keccak256("berc.role.MINT");

    /**
     * @notice Destroys any account's balance. The power `BehaviorFlags.SEIZABLE` declares.
     * @dev Separate from {MINT_ROLE} because they are separate powers and the flag word says so. It also
     *      covers burning a balance the holder controls itself: this assembly has no permissionless
     *      self-burn, so a treasury that wants to retire its own tokens holds this role — which is the same
     *      authority it would have needed before the split, not a new one.
     */
    bytes32 public constant SEIZE_ROLE = keccak256("berc.role.SEIZE");

    /// @notice Writes the on-chain metadata store and the token URI.
    bytes32 public constant METADATA_ROLE = keccak256("berc.role.METADATA");

    /// @notice Sets the fee rate, the cap, the vault, and per-account exemptions.
    bytes32 public constant FEE_CONFIG_ROLE = keccak256("berc.role.FEE_CONFIG");

    /// @notice Pauses transfers and freezes accounts.
    bytes32 public constant RESTRICTION_ROLE = keccak256("berc.role.RESTRICTION");

    /// @notice Installs and removes the transfer hook.
    bytes32 public constant HOOK_CONFIG_ROLE = keccak256("berc.role.HOOK_CONFIG");

    /// @notice The admin cannot be the zero address; the token would have no reachable authority.
    error ExtendedTokenInvalidAdmin();

    /// @notice An extension was requested that this assembly does not know how to install.
    error ExtendedTokenUnknownExtension(bytes4 extensionId);

    /**
     * @dev `extensionIds` names the extensions to install, using the same identifiers {extensions} will
     *      report back. Duplicates are rejected by `_registerExtension`, and anything this assembly does not
     *      recognise is rejected here, so the set a caller asks for is exactly the set they get or the
     *      deployment fails.
     *
     *      `_sealExtensions()` is deliberately *not* called here: the concrete token calls it last, after it
     *      has had a chance to declare deployment-level behaviour of its own.
     */
    function __ExtendedTokenBase_init(
        string memory name_,
        string memory symbol_,
        address admin,
        bytes4[] memory extensionIds
    ) internal onlyInitializing {
        if (admin == address(0)) revert ExtendedTokenInvalidAdmin();

        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        __ERC20ExtensionCore_init();

        for (uint256 i = 0; i < extensionIds.length; ++i) {
            if (!_initializeExtension(extensionIds[i])) revert ExtendedTokenUnknownExtension(extensionIds[i]);
        }

        // Declared by every assembly built on this base, whatever extensions it installs, because {mint}
        // and {burn} are on this contract and neither is optional. Leaving them out would let a token with
        // no extensions report `behaviorFlags() == 0` — which the vocabulary defines as indistinguishable
        // from a plain ERC-20 — while its supply authority could dilute every holder and take any balance.
        // Those are the two powers least visible in a simulation and most costly to discover afterwards.
        _declareBehavior(BehaviorFlags.MINTABLE | BehaviorFlags.SEIZABLE);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINT_ROLE, admin);
        _grantRole(SEIZE_ROLE, admin);
        _grantRole(METADATA_ROLE, admin);
        _grantRole(FEE_CONFIG_ROLE, admin);
        _grantRole(RESTRICTION_ROLE, admin);
        _grantRole(HOOK_CONFIG_ROLE, admin);
    }

    /**
     * @dev Installs one extension by identifier, returning false if it is not one of this assembly's.
     *      An assembly that inherits further modules overrides this, handles its own identifiers, and
     *      delegates the rest upward — which is how {BERCRuntimeV1} adds a fifth without restating these.
     */
    function _initializeExtension(bytes4 extensionId) internal virtual onlyInitializing returns (bool) {
        if (extensionId == ExtensionIds.ONCHAIN_METADATA) {
            __ERC20OnchainMetadata_init();
        } else if (extensionId == ExtensionIds.TRANSFER_FEE) {
            __ERC20TransferFee_init();
        } else if (extensionId == ExtensionIds.TRANSFER_RESTRICTION) {
            __ERC20TransferRestriction_init();
        } else if (extensionId == ExtensionIds.TRANSFER_HOOK) {
            __ERC20TransferHook_init();
        } else {
            return false;
        }
        return true;
    }

    /// @dev The four modules this assembly carries, which is what both reference tokens install.
    function _defaultExtensions() internal pure returns (bytes4[] memory extensionIds) {
        extensionIds = new bytes4[](4);
        extensionIds[0] = ExtensionIds.ONCHAIN_METADATA;
        extensionIds[1] = ExtensionIds.TRANSFER_FEE;
        extensionIds[2] = ExtensionIds.TRANSFER_RESTRICTION;
        extensionIds[3] = ExtensionIds.TRANSFER_HOOK;
    }

    /// @notice Creates `value` new tokens for `to`.
    function mint(address to, uint256 value) external virtual onlyRole(MINT_ROLE) {
        _mint(to, value);
    }

    /**
     * @notice Destroys `value` tokens held by `from`.
     * @dev Deliberately not restricted to the caller's own balance. An issuer that can freeze an account
     *      but not settle its balance has a freeze that cannot be resolved; see the table on
     *      `ERC20TransferRestriction` for why burning is the one flow a freeze does not block. That is
     *      what makes this {SEIZE_ROLE} and not {MINT_ROLE}: a key that can only add supply cannot reach
     *      anyone's balance.
     */
    function burn(address from, uint256 value) external virtual onlyRole(SEIZE_ROLE) {
        _burn(from, value);
    }

    /// @inheritdoc BERCAccessControl
    function _renounceManagedRoles(address account) internal virtual override {
        _revokeRole(MINT_ROLE, account);
        _revokeRole(SEIZE_ROLE, account);
        _revokeRole(METADATA_ROLE, account);
        _revokeRole(FEE_CONFIG_ROLE, account);
        _revokeRole(RESTRICTION_ROLE, account);
        _revokeRole(HOOK_CONFIG_ROLE, account);
    }

    // -----------------------------------------------------------------------------------------------
    // Linearisation plumbing
    //
    // Solidity requires a contract to restate any function it inherits from two or more sibling bases,
    // even when it has nothing to add. Each of these forwards straight to `super`, which walks the full
    // chain in the order C3 produced. They are bookkeeping, not behaviour: the transfer phase order is
    // decided in `ERC20ExtensionCore._update` and none of these can alter it.
    // -----------------------------------------------------------------------------------------------

    function _update(address from, address to, uint256 value)
        internal
        virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal
        view
        virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal
        virtual
        override(ERC20ExtensionCore, ERC20TransferFee)
        returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal
        virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal
        view
        virtual
        override(ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferRestriction, ERC20TransferHook)
        returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal
        view
        virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction)
        returns (bool)
    {
        return super._accountFrozen(account);
    }

    function _accountFeeExempt(address account)
        internal
        view
        virtual
        override(ERC20ExtensionCore, ERC20TransferFee)
        returns (bool)
    {
        return super._accountFeeExempt(account);
    }

    /**
     * @inheritdoc ERC20ExtensionCore
     * @dev The installed check comes first and is not redundant. An assembly that installs every module it
     *      inherits can never fail it, but a shared runtime installs a subset per token while still carrying
     *      every module's setters — without this, the fee authority of a token that has no fee extension
     *      could configure one, and `extensions()` would keep reporting that the token has none.
     */
    function _authorizeExtensionConfig(bytes4 extensionId) internal view virtual override {
        if (!hasExtension(extensionId)) revert ERC20ExtensionNotEnabled(extensionId);

        if (extensionId == ExtensionIds.ONCHAIN_METADATA) {
            _checkRole(METADATA_ROLE);
        } else if (extensionId == ExtensionIds.TRANSFER_FEE) {
            _checkRole(FEE_CONFIG_ROLE);
        } else if (extensionId == ExtensionIds.TRANSFER_RESTRICTION) {
            _checkRole(RESTRICTION_ROLE);
        } else if (extensionId == ExtensionIds.TRANSFER_HOOK) {
            _checkRole(HOOK_CONFIG_ROLE);
        } else {
            revert ERC20ExtensionNotEnabled(extensionId);
        }
    }
}
