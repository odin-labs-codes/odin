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
 * @title ExtendedToken
 * @notice The reference assembly: a plain ERC-20 to anyone who has never heard of this framework, and a
 *         fully declared one to anyone who has.
 *
 * @dev Deployed directly, with no proxy in front of it. Everything it does is fixed at deployment: the
 *      extension set, the behaviour word, and the code itself. This contract has no upgrade function and no
 *      admin slot, and `_disableInitializers()` runs at the end of the constructor so the initialisation
 *      path can never be re-entered, including through a delegatecall from somewhere else.
 *
 *      ## One role per authority
 *
 *      Each extension has its own role, reached through the single {_authorizeExtensionConfig} dispatch that
 *      every module's setters route into. The modules themselves know nothing about roles, so a different
 *      assembly can swap in `Ownable`, a timelock, or a governor without touching them.
 *
 *      The constructor grants every role to `admin` so that a deployment is usable immediately. Splitting
 *      them across separate keys is the expected next step.
 */
contract ExtendedToken is
    ERC20OnchainMetadata,
    ERC20TransferFee,
    ERC20TransferRestriction,
    ERC20TransferHook,
    AccessControlUpgradeable
{
    /// @notice Creates and destroys supply.
    bytes32 public constant SUPPLY_ROLE = keccak256("berc.role.SUPPLY");

    /// @notice Writes the on-chain metadata store.
    bytes32 public constant METADATA_ROLE = keccak256("berc.role.METADATA");

    /// @notice Sets the fee rate and the vault that collects fees.
    bytes32 public constant FEE_CONFIG_ROLE = keccak256("berc.role.FEE_CONFIG");

    /// @notice Pauses transfers and freezes accounts.
    bytes32 public constant RESTRICTION_ROLE = keccak256("berc.role.RESTRICTION");

    /// @notice Installs and removes the transfer hook.
    bytes32 public constant HOOK_CONFIG_ROLE = keccak256("berc.role.HOOK_CONFIG");

    /// @notice The admin cannot be the zero address; the token would have no reachable authority.
    error ExtendedTokenInvalidAdmin();

    /**
     * @param name_ ERC-20 name. Unchanged in meaning; wallets read it exactly as they always have.
     * @param symbol_ ERC-20 symbol.
     * @param admin Receives every role. Expected to redistribute them across separate authorities.
     */
    constructor(string memory name_, string memory symbol_, address admin) {
        _initializeExtendedToken(name_, symbol_, admin);
        _disableInitializers();
    }

    /**
     * @dev The module initialisers are `onlyInitializing`, which needs an `initializer` frame around them.
     *      OZ v5's `initializer` explicitly supports running inside a constructor, so this is the documented
     *      way to deploy an upgradeable-library contract without a proxy.
     */
    function _initializeExtendedToken(string memory name_, string memory symbol_, address admin) private initializer {
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

        // Fixes the extension set. Must be last.
        _sealExtensions();
    }

    /// @notice Creates `value` new tokens for `to`.
    function mint(address to, uint256 value) external virtual onlyRole(SUPPLY_ROLE) {
        _mint(to, value);
    }

    /// @notice Destroys `value` tokens held by `from`.
    function burn(address from, uint256 value) external virtual onlyRole(SUPPLY_ROLE) {
        _burn(from, value);
    }

    // -----------------------------------------------------------------------------------------------
    // Linearisation plumbing
    //
    // Solidity requires a contract to restate any function it inherits from two or more sibling bases, even
    // when it has nothing to add. Each of these forwards straight to `super`, which walks the full chain in
    // the order C3 produced. They are bookkeeping, not behaviour: the transfer phase order is decided in
    // `ERC20ExtensionCore._update` and none of these can alter it.
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
