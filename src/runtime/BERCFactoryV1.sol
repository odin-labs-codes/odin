// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {BERCRuntimeV1} from "./BERCRuntimeV1.sol";

/**
 * @title BERCFactoryV1
 * @notice Deploys canonical BERC tokens as clones of one runtime, and keeps a list of the ones it made.
 *
 * @dev Cloning and initialising have to happen in one transaction or a front-runner takes the clone and
 *      names themselves admin. That is the whole reason this contract exists: one call that cannot be
 *      interrupted halfway.
 *
 *      Anyone may clone {RUNTIME} without coming through here, and such a token is exactly as canonical as
 *      one this factory made — it runs the same code, which is the entire claim. The index below is for
 *      enumeration and UI, not for deciding whether to trust a token.
 */
contract BERCFactoryV1 {
    /// @notice The runtime every token from this factory delegates to.
    address public immutable RUNTIME;

    struct TokenParams {
        string name;
        string symbol;
        /// @dev Receives every role on the new token.
        address admin;
        /// @dev From {ExtensionIds}. May be empty. Duplicates, unknown ids and contradictory combinations
        ///      are all rejected by the runtime's initialiser.
        bytes4[] extensionIds;
    }

    address[] private _tokens;
    mapping(address token => bool) private _isDeployedToken;

    /// @notice A token was deployed. `extensionIds` is the set it was sealed with.
    event TokenDeployed(address indexed token, address indexed admin, bytes4[] extensionIds);

    /// @notice The runtime address passed to the constructor has no code.
    error BERCInvalidRuntime(address runtime);

    constructor(address runtime) {
        if (runtime.code.length == 0) revert BERCInvalidRuntime(runtime);
        RUNTIME = runtime;
    }

    /// @notice Deploys a token at an address determined by this factory's nonce.
    function deploy(TokenParams calldata params) external returns (address token) {
        token = Clones.clone(RUNTIME);

        BERCRuntimeV1(token).initialize(params.name, params.symbol, params.admin, params.extensionIds);

        _tokens.push(token);
        _isDeployedToken[token] = true;

        emit TokenDeployed(token, params.admin, params.extensionIds);
    }

    /// @notice How many tokens this factory has deployed.
    function tokenCount() external view returns (uint256) {
        return _tokens.length;
    }

    /// @notice The token at `index`, in deployment order. Append-only; indices are stable.
    function tokenAt(uint256 index) external view returns (address) {
        return _tokens[index];
    }

    /**
     * @notice Whether this factory deployed `token`.
     * @dev For enumeration and UI, not for deciding whether to trust a token.
     */
    function isDeployedToken(address token) external view returns (bool) {
        return _isDeployedToken[token];
    }
}
