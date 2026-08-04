// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// GENERATED FILE — do not edit by hand. Regenerate with `node tools/gen-combinations.mjs`.
//
// One concrete token for each of the 32 subsets of the five extension modules. Names carry the
// modules they contain: M = OnchainMetadata, F = TransferFee, R = TransferRestriction,
// N = NonTransferable, H = TransferHook. `Combo_None` has the registry and nothing else.
//
// `ExtensionMatrixTest` deploys every one of these from its build artifact, asserts that the permitted
// sets transfer correctly and that the forbidden sets revert inside their own constructor, and checks
// each one's `behaviorFlags()` against the modules it actually contains.

import {ERC20ExtensionCore} from "../../src/extensions/ERC20ExtensionCore.sol";
import {ERC20NonTransferable} from "../../src/extensions/ERC20NonTransferable.sol";
import {ERC20OnchainMetadata} from "../../src/extensions/ERC20OnchainMetadata.sol";
import {ERC20TransferFee} from "../../src/extensions/ERC20TransferFee.sol";
import {ERC20TransferHook} from "../../src/extensions/ERC20TransferHook.sol";
import {ERC20TransferRestriction} from "../../src/extensions/ERC20TransferRestriction.sol";

/// @dev no extensions.
contract Combo_None is ERC20ExtensionCore {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}
}

/// @dev ERC20OnchainMetadata.
contract Combo_M is ERC20OnchainMetadata {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}
}

/// @dev ERC20TransferFee.
contract Combo_F is ERC20TransferFee {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20TransferFee_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}
}

/// @dev ERC20OnchainMetadata, ERC20TransferFee.
contract Combo_MF is ERC20OnchainMetadata, ERC20TransferFee {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20TransferFee_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20OnchainMetadata, ERC20TransferFee) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}

/// @dev ERC20TransferRestriction.
contract Combo_R is ERC20TransferRestriction {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20TransferRestriction_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}
}

/// @dev ERC20OnchainMetadata, ERC20TransferRestriction.
contract Combo_MR is ERC20OnchainMetadata, ERC20TransferRestriction {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20TransferRestriction_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20OnchainMetadata, ERC20TransferRestriction) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }
}

/// @dev ERC20TransferFee, ERC20TransferRestriction.
contract Combo_FR is ERC20TransferFee, ERC20TransferRestriction {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20TransferFee_init();
        __ERC20TransferRestriction_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20TransferFee, ERC20TransferRestriction) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}

/// @dev ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferRestriction.
contract Combo_MFR is ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferRestriction {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20TransferFee_init();
        __ERC20TransferRestriction_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferRestriction) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}

/// @dev ERC20NonTransferable.
contract Combo_N is ERC20NonTransferable {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20NonTransferable_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}
}

/// @dev ERC20OnchainMetadata, ERC20NonTransferable.
contract Combo_MN is ERC20OnchainMetadata, ERC20NonTransferable {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20NonTransferable_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20OnchainMetadata) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }
}

/// @dev ERC20TransferFee, ERC20NonTransferable.
contract Combo_FN is ERC20TransferFee, ERC20NonTransferable {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20TransferFee_init();
        __ERC20NonTransferable_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}

/// @dev ERC20OnchainMetadata, ERC20TransferFee, ERC20NonTransferable.
contract Combo_MFN is ERC20OnchainMetadata, ERC20TransferFee, ERC20NonTransferable {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20TransferFee_init();
        __ERC20NonTransferable_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20OnchainMetadata, ERC20TransferFee) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}

/// @dev ERC20TransferRestriction, ERC20NonTransferable.
contract Combo_RN is ERC20TransferRestriction, ERC20NonTransferable {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20TransferRestriction_init();
        __ERC20NonTransferable_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20TransferRestriction, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }
}

/// @dev ERC20OnchainMetadata, ERC20TransferRestriction, ERC20NonTransferable.
contract Combo_MRN is ERC20OnchainMetadata, ERC20TransferRestriction, ERC20NonTransferable {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20TransferRestriction_init();
        __ERC20NonTransferable_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20OnchainMetadata, ERC20TransferRestriction) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }
}

/// @dev ERC20TransferFee, ERC20TransferRestriction, ERC20NonTransferable.
contract Combo_FRN is ERC20TransferFee, ERC20TransferRestriction, ERC20NonTransferable {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20TransferFee_init();
        __ERC20TransferRestriction_init();
        __ERC20NonTransferable_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee, ERC20TransferRestriction) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}

/// @dev ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferRestriction, ERC20NonTransferable.
contract Combo_MFRN is ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferRestriction, ERC20NonTransferable {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20TransferFee_init();
        __ERC20TransferRestriction_init();
        __ERC20NonTransferable_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferRestriction) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}

/// @dev ERC20TransferHook.
contract Combo_H is ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}
}

/// @dev ERC20OnchainMetadata, ERC20TransferHook.
contract Combo_MH is ERC20OnchainMetadata, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20OnchainMetadata, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }
}

/// @dev ERC20TransferFee, ERC20TransferHook.
contract Combo_FH is ERC20TransferFee, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20TransferFee_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20TransferFee, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}

/// @dev ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferHook.
contract Combo_MFH is ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20TransferFee_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}

/// @dev ERC20TransferRestriction, ERC20TransferHook.
contract Combo_RH is ERC20TransferRestriction, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20TransferRestriction_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20TransferRestriction, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }
}

/// @dev ERC20OnchainMetadata, ERC20TransferRestriction, ERC20TransferHook.
contract Combo_MRH is ERC20OnchainMetadata, ERC20TransferRestriction, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20TransferRestriction_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20OnchainMetadata, ERC20TransferRestriction, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }
}

/// @dev ERC20TransferFee, ERC20TransferRestriction, ERC20TransferHook.
contract Combo_FRH is ERC20TransferFee, ERC20TransferRestriction, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20TransferFee_init();
        __ERC20TransferRestriction_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20TransferFee, ERC20TransferRestriction, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}

/// @dev ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferRestriction, ERC20TransferHook.
contract Combo_MFRH is ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferRestriction, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20TransferFee_init();
        __ERC20TransferRestriction_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferRestriction, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}

/// @dev ERC20NonTransferable, ERC20TransferHook.
contract Combo_NH is ERC20NonTransferable, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20NonTransferable_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }
}

/// @dev ERC20OnchainMetadata, ERC20NonTransferable, ERC20TransferHook.
contract Combo_MNH is ERC20OnchainMetadata, ERC20NonTransferable, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20NonTransferable_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20OnchainMetadata, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }
}

/// @dev ERC20TransferFee, ERC20NonTransferable, ERC20TransferHook.
contract Combo_FNH is ERC20TransferFee, ERC20NonTransferable, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20TransferFee_init();
        __ERC20NonTransferable_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}

/// @dev ERC20OnchainMetadata, ERC20TransferFee, ERC20NonTransferable, ERC20TransferHook.
contract Combo_MFNH is ERC20OnchainMetadata, ERC20TransferFee, ERC20NonTransferable, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20TransferFee_init();
        __ERC20NonTransferable_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}

/// @dev ERC20TransferRestriction, ERC20NonTransferable, ERC20TransferHook.
contract Combo_RNH is ERC20TransferRestriction, ERC20NonTransferable, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20TransferRestriction_init();
        __ERC20NonTransferable_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }
}

/// @dev ERC20OnchainMetadata, ERC20TransferRestriction, ERC20NonTransferable, ERC20TransferHook.
contract Combo_MRNH is ERC20OnchainMetadata, ERC20TransferRestriction, ERC20NonTransferable, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20TransferRestriction_init();
        __ERC20NonTransferable_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20OnchainMetadata, ERC20TransferRestriction, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }
}

/// @dev ERC20TransferFee, ERC20TransferRestriction, ERC20NonTransferable, ERC20TransferHook.
contract Combo_FRNH is ERC20TransferFee, ERC20TransferRestriction, ERC20NonTransferable, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20TransferFee_init();
        __ERC20TransferRestriction_init();
        __ERC20NonTransferable_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee, ERC20TransferRestriction, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}

/// @dev ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferRestriction, ERC20NonTransferable, ERC20TransferHook.
contract Combo_MFRNH is ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferRestriction, ERC20NonTransferable, ERC20TransferHook {
    constructor(string memory name_, string memory symbol_) {
        _initializeCombo(name_, symbol_);
        _disableInitializers();
    }

    function _initializeCombo(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20OnchainMetadata_init();
        __ERC20TransferFee_init();
        __ERC20TransferRestriction_init();
        __ERC20NonTransferable_init();
        __ERC20TransferHook_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    /// @dev Open on purpose: the matrix exercises configuration, not authorisation.
    function _authorizeExtensionConfig(bytes4) internal view override {}

    function _update(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._update(from, to, value);
    }

    function _checkTransferAllowed(address from, address to, uint256 value)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal virtual
        override(ERC20ExtensionCore, ERC20TransferHook)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal view virtual
        override(ERC20ExtensionCore, ERC20OnchainMetadata, ERC20TransferFee, ERC20TransferRestriction, ERC20TransferHook) returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferRestriction) returns (bool)
    {
        return super._accountFrozen(account);
    }

    function _accountFeeExempt(address account)
        internal view virtual
        override(ERC20ExtensionCore, ERC20TransferFee) returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}
