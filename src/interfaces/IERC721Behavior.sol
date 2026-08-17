// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC721Behavior
 * @notice One call that tells an integrator every way this collection departs from a plain ERC-721.
 *
 * @dev The selector is the same one {IERC20Behavior} declares, and deliberately so: an integrator holding
 *      an address it has not yet classified can ask this question before it knows which token standard it
 *      is looking at, and gets an answer in the same vocabulary either way. See {BehaviorFlags}.
 *
 *      What a non-fungible token makes harder is that the most expensive surprise is not in the token's
 *      behaviour but in the *caller's*. A collection can move perfectly well for its owner and refuse every
 *      transfer a given marketplace attempts, and no simulation an integrator runs on their own behalf will
 *      show it. That is why `OPERATOR_RESTRICTED` exists and why this call is worth making before listing
 *      rather than after the first failed settlement.
 */
interface IERC721Behavior {
    /**
     * @notice A bitmask of every declared behaviour, from {BehaviorFlags}.
     * @dev Fixed at deployment unless `UPGRADEABLE` is set, so it is safe to read once and cache next to
     *      the collection address. A revert means the collection does not implement this interface at all,
     *      which is emphatically **not** the same as an answer of `0` — see the integration guide.
     */
    function behaviorFlags() external view returns (uint256);
}
