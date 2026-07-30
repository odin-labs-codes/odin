// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ExtendedTokenBase} from "../ExtendedTokenBase.sol";
import {ERC20ExtensionCore} from "../extensions/ERC20ExtensionCore.sol";
import {ERC20NonTransferable} from "../extensions/ERC20NonTransferable.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";

/**
 * @title BERCRuntimeV1
 * @notice One deployed contract that every canonical BERC token executes, with its extension set chosen per
 *         token at initialisation and frozen there.
 *
 * @dev Token-2022's guarantees come from there being exactly one program. A wallet does not audit each mint;
 *      it audits the program once, and every mint inherits that audit. This contract is the closest an EVM
 *      chain gets: deployed once, never upgraded, and pointed at by every token built on it.
 *
 *      New capability arrives as a new runtime and new tokens, never as a change to these. Existing tokens
 *      keeping their behaviour forever is the product, not a limitation of it.
 *
 *      ## Why every module is inherited but only some are installed
 *
 *      A token on a shared runtime cannot add code, so the runtime has to carry every extension any token
 *      might want, and each token turns on a subset. Modules that read configuration are naturally inert
 *      when unconfigured — an unregistered fee module has a zero rate, an unregistered restriction module
 *      blocks nothing. The one exception is `ERC20NonTransferable`, whose check is unconditional by
 *      design, so it is gated on registration through `_nonTransferableActive`.
 */
contract BERCRuntimeV1 is ExtendedTokenBase, ERC20NonTransferable {
    /// @notice Human-readable identity. The address of this contract is the identity that actually matters.
    string public constant RUNTIME_NAME = "BERC Runtime";

    /// @notice Bumped only by deploying a new runtime; this one will always answer 1.
    uint256 public constant RUNTIME_VERSION = 1;

    /**
     * @dev Locks the implementation's own storage, so this address can never be initialised directly and
     *      then presented as a token in its own right.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialises one token on this runtime. Callable exactly once.
     * @param extensionIds The extensions to install, from {ExtensionIds}. May be empty, which produces a
     *        token whose transfers behave exactly like a plain ERC-20's — a useful thing to be able to
     *        prove. It is still not a plain ERC-20: like every token on this runtime it declares
     *        `MINTABLE | SEIZABLE`, because `mint` and `burn(from, value)` live on the shared base and no
     *        extension set can remove them.
     * @param admin Receives every role.
     */
    function initialize(string calldata name_, string calldata symbol_, address admin, bytes4[] calldata extensionIds)
        external
        initializer
    {
        __ExtendedTokenBase_init(name_, symbol_, admin, extensionIds);
        // Fixes the extension set and rejects contradictory declarations, such as a token asking to be both
        // non-transferable and fee-bearing. Must be last.
        _sealExtensions();
    }

    /// @inheritdoc ExtendedTokenBase
    function _initializeExtension(bytes4 extensionId) internal virtual override onlyInitializing returns (bool) {
        if (extensionId == ExtensionIds.NON_TRANSFERABLE) {
            __ERC20NonTransferable_init();
            return true;
        }
        return super._initializeExtension(extensionId);
    }

    /// @inheritdoc ERC20NonTransferable
    function _nonTransferableActive() internal view virtual override returns (bool) {
        return hasExtension(ExtensionIds.NON_TRANSFERABLE);
    }

    // -----------------------------------------------------------------------------------------------
    // Linearisation plumbing
    //
    // Adding a fifth module alongside `ExtendedTokenBase` makes every function the two chains share
    // ambiguous again, so each is restated once and forwarded to `super`. As in `ExtendedTokenBase`, none
    // of these decides anything: `ERC20ExtensionCore._update` still owns the phase order, and the order
    // these appear in cannot change it.
    // -----------------------------------------------------------------------------------------------

    /// @dev Both bases screen transfers, and both checks run.
    function _checkTransferAllowed(address from, address to, uint256 value)
        internal
        view
        virtual
        override(ExtendedTokenBase, ERC20NonTransferable)
    {
        super._checkTransferAllowed(from, to, value);
    }

    function _update(address from, address to, uint256 value)
        internal
        virtual
        override(ExtendedTokenBase, ERC20ExtensionCore)
    {
        super._update(from, to, value);
    }

    function _collectTransferFee(address from, address to, uint256 value)
        internal
        virtual
        override(ExtendedTokenBase, ERC20ExtensionCore)
        returns (uint256)
    {
        return super._collectTransferFee(from, to, value);
    }

    function _afterTransfer(address from, address to, uint256 value)
        internal
        virtual
        override(ExtendedTokenBase, ERC20ExtensionCore)
    {
        super._afterTransfer(from, to, value);
    }

    function _extensionData(bytes4 extensionId)
        internal
        view
        virtual
        override(ExtendedTokenBase, ERC20ExtensionCore)
        returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _accountFrozen(address account)
        internal
        view
        virtual
        override(ExtendedTokenBase, ERC20ExtensionCore)
        returns (bool)
    {
        return super._accountFrozen(account);
    }

    function _accountFeeExempt(address account)
        internal
        view
        virtual
        override(ExtendedTokenBase, ERC20ExtensionCore)
        returns (bool)
    {
        return super._accountFeeExempt(account);
    }
}
