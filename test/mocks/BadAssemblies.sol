// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20ExtensionCore} from "../../src/extensions/ERC20ExtensionCore.sol";
import {ERC20TransferFee} from "../../src/extensions/ERC20TransferFee.sol";
import {BehaviorFlags} from "../../src/libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../../src/libraries/ExtensionIds.sol";

/// @dev Registers the same module twice.
contract DoubleRegisterToken is ERC20TransferFee {
    constructor() {
        _init();
    }

    function _init() private initializer {
        __ERC20_init("Double", "DBL");
        __ERC20ExtensionCore_init();
        __ERC20TransferFee_init();
        __ERC20TransferFee_init();
        _sealExtensions();
    }

    function _authorizeExtensionConfig(bytes4) internal view override {}
}

/// @dev Seals the registry, then keeps going.
contract RegisterAfterSealToken is ERC20TransferFee {
    constructor() {
        _init();
    }

    function _init() private initializer {
        __ERC20_init("Late", "LATE");
        __ERC20ExtensionCore_init();
        _sealExtensions();
        __ERC20TransferFee_init();
    }

    function _authorizeExtensionConfig(bytes4) internal view override {}
}

/// @dev Seals twice.
contract DoubleSealToken is ERC20TransferFee {
    constructor() {
        _init();
    }

    function _init() private initializer {
        __ERC20_init("Sealed", "SEAL");
        __ERC20ExtensionCore_init();
        __ERC20TransferFee_init();
        _sealExtensions();
        _sealExtensions();
    }

    function _authorizeExtensionConfig(bytes4) internal view override {}
}

/// @dev Declares a behaviour bit outside the vocabulary. A bit nobody has assigned meaning to is worse
///      than no declaration at all: an integrator reading it cannot tell whether they are missing
///      something dangerous or looking at a typo.
contract UnknownFlagToken is ERC20ExtensionCore {
    constructor() {
        _init();
    }

    function _init() private initializer {
        __ERC20_init("Unknown", "UNK");
        __ERC20ExtensionCore_init();
        _declareBehavior(1 << 200);
        _sealExtensions();
    }

    function _authorizeExtensionConfig(bytes4) internal view override {}
}

/// @dev Declares behaviour after the registry was sealed.
contract DeclareAfterSealToken is ERC20ExtensionCore {
    constructor() {
        _init();
    }

    function _init() private initializer {
        __ERC20_init("Late Flag", "LFLG");
        __ERC20ExtensionCore_init();
        _sealExtensions();
        _declareBehavior(BehaviorFlags.UPGRADEABLE);
    }

    function _authorizeExtensionConfig(bytes4) internal view override {}
}

/// @dev A third-party fee module that charges more than the transfer carries. The core has to catch this,
///      because the alternative is an underflow on the main leg — or, without the checked arithmetic, a
///      transfer that credits the recipient an enormous number.
contract OverchargingFeeToken is ERC20ExtensionCore {
    constructor() {
        _init();
    }

    function _init() private initializer {
        __ERC20_init("Overcharge", "OVER");
        __ERC20ExtensionCore_init();
        _registerExtension(ExtensionIds.TRANSFER_FEE, BehaviorFlags.FEE_ON_TRANSFER);
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function _collectTransferFee(address, address, uint256 value) internal pure override returns (uint256) {
        return value + 1;
    }

    function _authorizeExtensionConfig(bytes4) internal view override {}
}
