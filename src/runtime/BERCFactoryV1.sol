// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {BERCRuntimeV1} from "./BERCRuntimeV1.sol";

/**
 * @title BERCFactoryV1
 * @notice Deploys canonical BERC tokens as clones of one runtime, and keeps a list of the ones it made.
 *
 * @dev Anyone may clone {RUNTIME} without coming through here, and such a token is exactly as canonical as
 *      one this factory made — it runs the same code, which is the entire claim. The index below is for
 *      enumeration and UI, not for deciding whether to trust a token.
 *
 *      ## What it does that a bare clone would get wrong
 *
 *      Cloning and initialising have to happen in one transaction or a front-runner takes the clone. The
 *      initial fee configuration has to be applied by an address holding the fee role, which means the
 *      deployer briefly holds roles it must then give up — and give up in the right order, since
 *      `DEFAULT_ADMIN_ROLE` is what authorises the other revocations and dropping it first strands the rest.
 *      All of that is one call here.
 */
contract BERCFactoryV1 {
    /// @notice The runtime every token from this factory delegates to.
    address public immutable RUNTIME;

    /**
     * @dev One address per role. Any field left zero falls back to `admin`, so a caller who does not care
     *      about the split still gets a working token, and one who does never has to follow the deployment
     *      with a second transaction that re-grants and revokes.
     */
    struct Authorities {
        address fee;
        address restriction;
        address supply;
        address metadata;
        address hook;
    }

    struct TokenParams {
        string name;
        string symbol;
        /// @dev Receives `DEFAULT_ADMIN_ROLE`, plus any role `authorities` leaves unset.
        address admin;
        /// @dev Per-role holders. Zero fields default to `admin`.
        Authorities authorities;
        /// @dev From {ExtensionIds}. May be empty. Duplicates, unknown ids and contradictory combinations
        ///      are all rejected by the runtime's initialiser.
        bytes4[] extensionIds;
        /// @dev The three fields below are meaningful only with `TRANSFER_FEE` installed.
        address feeVault;
        uint16 feeBasisPoints;
        uint256 maximumFee;
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
        token = _configure(Clones.clone(RUNTIME), params);
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

    function _configure(address token, TokenParams calldata params) private returns (address) {
        bool wantsFee = _requests(params.extensionIds, ExtensionIds.TRANSFER_FEE);

        BERCRuntimeV1 deployed = BERCRuntimeV1(token);
        deployed.initialize(params.name, params.symbol, address(this), params.extensionIds);

        if (wantsFee) {
            deployed.setFeeVault(params.feeVault);
            deployed.setFeeConfig(params.feeBasisPoints, params.maximumFee);
            // No `setFeeExempt` for the vault. `isFeeExempt` already answers true for whichever address is
            // *currently* the vault, so an explicit exemption here would be redundant on day one and wrong
            // later: rotating the vault would leave the old address permanently exempt, with nothing in
            // the deployment record explaining why.
        }

        _handOverRoles(deployed, params);

        _tokens.push(token);
        _isDeployedToken[token] = true;

        emit TokenDeployed(token, params.admin, params.extensionIds);
        return token;
    }

    /**
     * @dev Grants each role to its intended holder, then drops every role this factory holds.
     *      `DEFAULT_ADMIN_ROLE` is last in both arrays on purpose: it authorises the other revocations, so
     *      revoking it earlier would leave the factory permanently holding whatever came after it.
     *
     *      Splitting here rather than leaving it to a follow-up transaction matters because the window
     *      between them is one where a single key holds everything — which is the state the split exists
     *      to avoid, and the state an interrupted deployment would be stuck in.
     */
    function _handOverRoles(BERCRuntimeV1 token, TokenParams calldata params) private {
        address admin = params.admin;
        bytes32[6] memory roles = [
            token.SUPPLY_ROLE(),
            token.METADATA_ROLE(),
            token.FEE_CONFIG_ROLE(),
            token.RESTRICTION_ROLE(),
            token.HOOK_CONFIG_ROLE(),
            token.DEFAULT_ADMIN_ROLE()
        ];
        address[6] memory holders = [
            _orAdmin(params.authorities.supply, admin),
            _orAdmin(params.authorities.metadata, admin),
            _orAdmin(params.authorities.fee, admin),
            _orAdmin(params.authorities.restriction, admin),
            _orAdmin(params.authorities.hook, admin),
            admin
        ];

        for (uint256 i = 0; i < roles.length; ++i) {
            token.grantRole(roles[i], holders[i]);
        }
        for (uint256 i = 0; i < roles.length; ++i) {
            if (holders[i] != address(this)) token.revokeRole(roles[i], address(this));
        }
    }

    function _orAdmin(address authority, address admin) private pure returns (address) {
        return authority == address(0) ? admin : authority;
    }

    function _requests(bytes4[] calldata extensionIds, bytes4 wanted) private pure returns (bool) {
        for (uint256 i = 0; i < extensionIds.length; ++i) {
            if (extensionIds[i] == wanted) return true;
        }
        return false;
    }
}
