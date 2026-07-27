// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ExtendedTokenBase} from "./ExtendedTokenBase.sol";

/**
 * @title ExtendedToken
 * @notice The reference assembly: a plain ERC-20 to anyone who has never heard of this framework, and a
 *         fully declared one to anyone who has.
 *
 * @dev Deployed directly, with no proxy in front of it. Everything it does is fixed at deployment: the
 *      extension set, the behaviour word, and the code itself. This contract has no upgrade function, no
 *      admin slot, and `_disableInitializers()` runs at the end of the constructor so the initialisation path
 *      can never be re-entered, including through a delegatecall from somewhere else.
 *
 *      ## Why an "immutable" contract is built on the upgradeable libraries
 *
 *      The extension modules are written once, against `ERC20Upgradeable`, and serve both this contract and
 *      whatever proxied shell comes next. The alternative — two parallel trees — would mean the fee
 *      arithmetic and the transfer pipeline existed in two places. One implementation, two shells.
 *
 *      The only thing `ERC20Upgradeable` changes at runtime is which slot the balance mapping lives in.
 *      Every function, event and revert an integrator can observe is identical to `ERC20`.
 */
contract ExtendedToken is ExtendedTokenBase {
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
        __ExtendedTokenBase_init(name_, symbol_, admin);
        // Fixes the extension set. Must be last.
        _sealExtensions();
    }
}
