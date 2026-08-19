// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {BERCNFTRuntimeV1} from "./BERCNFTRuntimeV1.sol";

/**
 * @title BERCNFTFactoryV1
 * @notice Deploys verifiable BERC collections as EIP-1167 clones of one runtime. Immutable, and nobody
 *         owns it.
 *
 * @dev The non-fungible counterpart of {BERCFactoryV1}, with the same two reasons for existing.
 *
 *      The first is that a clone is 45 bytes, so deployment is cheap enough that a collection has no excuse
 *      to be unverifiable. The second is the part that is easy to get wrong by hand: between `initialize`
 *      and the last `revokeRole`, some address holds every authority over the collection. Doing that in a
 *      follow-up transaction leaves a window where one key can pause the collection, rewrite every token's
 *      metadata and burn anything it likes — and an interrupted deployment stays in that state. Here the
 *      whole sequence is one call, and the roles are split at creation.
 *
 *      This factory is not the trust anchor and does not want to be. {isDeployedCollection} is for
 *      enumeration; deciding whether to believe a collection is `BERCVerification.isClonedFrom(collection,
 *      RUNTIME)`, which needs no call to anything and does not care whether this factory was involved.
 */
contract BERCNFTFactoryV1 {
    /// @notice The runtime every collection from this factory delegates to. Pass this to {BERCVerification}.
    address public immutable RUNTIME;

    /**
     * @dev One address per role. Any field left zero falls back to `admin`, so a caller who does not care
     *      about the split still gets a working collection, and one who does never has to follow the
     *      deployment with a second transaction that re-grants and revokes.
     */
    struct Authorities {
        address operatorPolicy;
        address restriction;
        address mint;
        address seize;
        address metadata;
    }

    struct CollectionParams {
        string name;
        string symbol;
        /// @dev Receives `DEFAULT_ADMIN_ROLE`, plus any role `authorities` leaves unset.
        address admin;
        /// @dev Per-role holders. Zero fields default to `admin`.
        Authorities authorities;
        /// @dev From {ExtensionIds}. May be empty. Duplicates, unknown ids and contradictory combinations
        ///      are all rejected by the runtime's initialiser.
        bytes4[] extensionIds;
        /// @dev Meaningful only with `NFT_MUTABLE_METADATA` installed, and must be empty otherwise rather
        ///      than silently ignored.
        string baseURI;
        /// @dev Meaningful only with `NFT_OPERATOR_RESTRICTION` installed. Leaving it false is the usual
        ///      choice: the allowlist is empty at this point, so enforcing immediately means no operator
        ///      can move anything until the policy authority populates it.
        bool enforceOperatorAllowlist;
    }

    address[] private _collections;
    mapping(address collection => bool) private _isDeployedCollection;

    /// @notice A collection was deployed. `collection` is already verifiable against {RUNTIME}.
    event CollectionDeployed(address indexed collection, address indexed admin, bytes4[] extensionIds);

    /// @notice The runtime address has no code, so every clone of it would be inert.
    error BERCNFTInvalidRuntime(address runtime);

    /// @notice The admin cannot be zero, and cannot be this factory — it gives up every role before it
    ///         returns, so a collection admined by it would have no reachable authority at all.
    error BERCNFTInvalidAdmin(address admin);

    /// @notice Metadata configuration was supplied without the metadata extension to apply it to.
    error BERCNFTMetadataConfigWithoutMetadataExtension();

    /// @notice Operator-policy configuration was supplied without the operator extension to apply it to.
    error BERCNFTOperatorConfigWithoutOperatorExtension();

    constructor(address runtime) {
        if (runtime.code.length == 0) revert BERCNFTInvalidRuntime(runtime);
        RUNTIME = runtime;
    }

    /// @notice Deploys one collection at an address nobody chose.
    function deploy(CollectionParams calldata params) external returns (address collection) {
        collection = _configure(Clones.clone(RUNTIME), params);
    }

    /**
     * @notice Deploys one collection at an address derived from `salt` and the caller.
     * @dev The caller is mixed into the salt, so two deployers using the same salt cannot collide and
     *      nobody can front-run a known salt to occupy an address. Use {predictDeterministicAddress} with
     *      the same pair to compute the result first.
     */
    function deployDeterministic(CollectionParams calldata params, bytes32 salt)
        external
        returns (address collection)
    {
        collection = _configure(Clones.cloneDeterministic(RUNTIME, _salt(msg.sender, salt)), params);
    }

    /// @notice The address {deployDeterministic} will produce for `deployer` and `salt`.
    function predictDeterministicAddress(address deployer, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(RUNTIME, _salt(deployer, salt), address(this));
    }

    /// @notice How many collections this factory has deployed.
    function collectionCount() external view returns (uint256) {
        return _collections.length;
    }

    /// @notice The collection at `index`, in deployment order. Append-only; indices are stable.
    function collectionAt(uint256 index) external view returns (address) {
        return _collections[index];
    }

    /**
     * @notice Whether this factory deployed `collection`.
     * @dev For enumeration and UI, not for deciding whether to trust a collection. A `false` here says
     *      nothing about the code — use {BERCVerification-isClonedFrom} against {RUNTIME} for that.
     */
    function isDeployedCollection(address collection) external view returns (bool) {
        return _isDeployedCollection[collection];
    }

    function _configure(address collection, CollectionParams calldata params) private returns (address) {
        if (params.admin == address(0) || params.admin == address(this)) revert BERCNFTInvalidAdmin(params.admin);

        bool wantsMetadata = _requests(params.extensionIds, ExtensionIds.NFT_MUTABLE_METADATA);
        if (!wantsMetadata && bytes(params.baseURI).length != 0) {
            revert BERCNFTMetadataConfigWithoutMetadataExtension();
        }

        bool wantsOperatorPolicy = _requests(params.extensionIds, ExtensionIds.NFT_OPERATOR_RESTRICTION);
        if (!wantsOperatorPolicy && params.enforceOperatorAllowlist) {
            revert BERCNFTOperatorConfigWithoutOperatorExtension();
        }

        BERCNFTRuntimeV1 deployed = BERCNFTRuntimeV1(collection);
        deployed.initialize(params.name, params.symbol, address(this), params.extensionIds);

        if (wantsMetadata && bytes(params.baseURI).length != 0) {
            deployed.setBaseURI(params.baseURI);
        }
        if (params.enforceOperatorAllowlist) {
            // Deliberately no seeding of the allowlist here. An operator the factory added would be an
            // operator the deployment record does not explain, and every entry is readable from
            // `OperatorAllowed` logs only if it was added by the authority that owns the policy.
            deployed.setOperatorAllowlistEnforced(true);
        }

        _handOverRoles(deployed, params);

        _collections.push(collection);
        _isDeployedCollection[collection] = true;

        emit CollectionDeployed(collection, params.admin, params.extensionIds);
        return collection;
    }

    /**
     * @dev Grants each role to its intended holder, then drops every role this factory holds.
     *      `DEFAULT_ADMIN_ROLE` is last in both arrays on purpose: it authorises the other revocations, so
     *      revoking it earlier would leave the factory permanently holding whatever came after it.
     */
    function _handOverRoles(BERCNFTRuntimeV1 collection, CollectionParams calldata params) private {
        address admin = params.admin;
        bytes32[6] memory roles = [
            collection.OPERATOR_POLICY_ROLE(),
            collection.RESTRICTION_ROLE(),
            collection.MINT_ROLE(),
            collection.SEIZE_ROLE(),
            collection.METADATA_ROLE(),
            collection.DEFAULT_ADMIN_ROLE()
        ];
        address[6] memory holders = [
            _orAdmin(params.authorities.operatorPolicy, admin),
            _orAdmin(params.authorities.restriction, admin),
            _orAdmin(params.authorities.mint, admin),
            _orAdmin(params.authorities.seize, admin),
            _orAdmin(params.authorities.metadata, admin),
            admin
        ];

        for (uint256 i = 0; i < roles.length; ++i) {
            collection.grantRole(roles[i], holders[i]);
        }
        for (uint256 i = 0; i < roles.length; ++i) {
            if (holders[i] != address(this)) collection.revokeRole(roles[i], address(this));
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

    function _salt(address deployer, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(deployer, salt));
    }
}
