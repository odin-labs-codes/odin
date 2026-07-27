// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {ERC20ExtensionCore} from "./extensions/ERC20ExtensionCore.sol";
import {ERC20OnchainMetadata} from "./extensions/ERC20OnchainMetadata.sol";
import {ERC20TransferFee} from "./extensions/ERC20TransferFee.sol";
import {ERC20TransferHook} from "./extensions/ERC20TransferHook.sol";
import {ERC20TransferRestriction} from "./extensions/ERC20TransferRestriction.sol";
import {ExtensionIds} from "./libraries/ExtensionIds.sol";

/**
 * @title ExtendedTokenBase
 * @notice The shared assembly behind the reference tokens: four extension modules, one role per authority,
 *         and nothing else.
 *
 * @dev Extracted from `ExtendedToken` so that an immutable deployment and a proxied one can be two thin
 *      shells over one assembly. The alternative — two parallel trees — would mean the fee arithmetic and
 *      the transfer pipeline existed in two places, and the pipeline is the part of this codebase where a
 *      divergence would be least visible and most expensive.
 *
 *      The order the modules are listed in below does not affect behaviour — `ERC20ExtensionCore` owns the
 *      only `_update` and fixes the phase order there. This is a property worth relying on: a third party
 *      assembling their own token cannot get the ordering wrong by listing modules in the order that reads
 *      best.
 *
 *      ## One role per authority
 *
 *      Each extension has its own role, reached through the single {_authorizeExtensionConfig} dispatch
 *      that every module's setters route into. The modules themselves know nothing about roles, so a
 *      different assembly can swap in `Ownable`, a timelock, or a governor without touching them.
 *
 *      The initialiser grants every role to `admin` so that a deployment is usable immediately. Splitting
 *      them across separate keys is the expected next step.
 */
abstract contract ExtendedTokenBase is
    ERC20OnchainMetadata,
    ERC20TransferFee,
    ERC20TransferRestriction,
    ERC20TransferHook,
    AccessControlUpgradeable
{
    /// @notice Creates and destroys supply.
    bytes32 public constant SUPPLY_ROLE = keccak256("berc.role.SUPPLY");

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

    /**
     * @dev `_sealExtensions()` is deliberately *not* called here: the concrete token calls it last, after it
     *      has had a chance to declare deployment-level behaviour of its own.
     */
    function __ExtendedTokenBase_init(string memory name_, string memory symbol_, address admin)
        internal
        onlyInitializing
    {
        if (admin == address(0)) revert ExtendedTokenInvalidAdmin();

        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        __ERC20ExtensionCore_init();

        __ERC20OnchainMetadata_init();
        __ERC20TransferFee_init();
        __ERC20TransferRestriction_init();
        __ERC20TransferHook_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SUPPLY_ROLE, admin);
        _grantRole(METADATA_ROLE, admin);
        _grantRole(FEE_CONFIG_ROLE, admin);
        _grantRole(RESTRICTION_ROLE, admin);
        _grantRole(HOOK_CONFIG_ROLE, admin);
    }

    /// @notice Creates `value` new tokens for `to`.
    function mint(address to, uint256 value) external virtual onlyRole(SUPPLY_ROLE) {
        _mint(to, value);
    }

    /**
     * @notice Destroys `value` tokens held by `from`.
     * @dev Deliberately not restricted to the caller's own balance. An issuer that can freeze an account
     *      but not settle its balance has a freeze that cannot be resolved; see the table on
     *      `ERC20TransferRestriction` for why burning is the one flow a freeze does not block.
     */
    function burn(address from, uint256 value) external virtual onlyRole(SUPPLY_ROLE) {
        _burn(from, value);
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

    /// @inheritdoc ERC20ExtensionCore
    function _authorizeExtensionConfig(bytes4 extensionId) internal view virtual override {
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
