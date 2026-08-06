// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev An ordinary OpenZeppelin ERC-20 with no extensions and no discovery surface. Used as the other
///      side of the mock pool, and to check that an extension-aware integrator handles a token that does
///      not answer `behaviorFlags()` at all.
contract PlainERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }
}
