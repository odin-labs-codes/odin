// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20TransferFee} from "../../src/extensions/ERC20TransferFee.sol";

/// @dev An assembly that registers a module and then forgets to call `_sealExtensions()`. Exists to pin
///      the consequence: the discovery surface is dead rather than quietly reporting an unvalidated set.
contract UnsealedToken is ERC20TransferFee {
    constructor() {
        _initializeUnsealed();
    }

    function _initializeUnsealed() private initializer {
        __ERC20_init("Unsealed", "UNSEAL");
        __ERC20ExtensionCore_init();
        __ERC20TransferFee_init();
        // _sealExtensions() deliberately omitted.
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function _authorizeExtensionConfig(bytes4) internal view override {}
}
