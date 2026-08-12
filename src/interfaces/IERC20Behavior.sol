// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC20Behavior
 * @notice One call that tells an integrator every way this token departs from a plain ERC-20.
 *
 * @dev A protocol deciding whether to list a token should not have to probe for fee-on-transfer by
 *      simulating a transfer, or discover a pause switch by reading storage layouts. It should be able to
 *      ask. The bit values are defined in `BehaviorFlags`; a zero word means the token behaves exactly as
 *      an integrator who has never heard of this framework would assume.
 *
 *      The returned word is fixed at deployment. See `BehaviorFlags` for why it tracks the installed
 *      extension set rather than the current configuration.
 */
interface IERC20Behavior {
    /// @notice Bitfield of declared non-standard behaviours. See `BehaviorFlags`.
    function behaviorFlags() external view returns (uint256);
}
