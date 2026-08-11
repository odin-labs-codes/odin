// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ExtendedToken} from "../src/ExtendedToken.sol";
import {ExtendedTokenBase} from "../src/ExtendedTokenBase.sol";
import {ExtendedTokenUpgradeable} from "../src/ExtendedTokenUpgradeable.sol";

/// @dev One address per authority, mirroring Token-2022's separate keys.
struct Authorities {
    address admin;
    address fee;
    address restriction;
    address mint;
    address seize;
    address metadata;
    address hook;
}

/**
 * @title DeployBase
 * @notice Shared reading, role handover and postcondition checks for both reference deployments.
 *
 * @dev The two scripts diverged once before — the upgradeable one documented `FEE_AUTHORITY` and friends
 *      and then quietly granted everything to `ADMIN` — so the distribution lives here exactly once and
 *      both scripts assert the result rather than assuming it.
 */
abstract contract DeployBase is Script {
    /**
     * @dev Reads every authority, defaulting each to `ADMIN` so a minimal environment still deploys.
     *
     *      Every one of them is checked against zero here, because nothing downstream will. The token's own
     *      {ExtendedTokenBase-ExtendedTokenInvalidAdmin} guard runs against the address passed to the
     *      constructor, and these scripts pass the broadcaster so they can configure the token before
     *      handing it over — so the guard never sees the address that actually ends up holding the roles.
     *      `grantRole` will happily grant to zero, and the result is a token whose fee, restrictions,
     *      supply, metadata, hook and upgrade authority are all permanently unreachable, with no way to
     *      recover because `DEFAULT_ADMIN_ROLE` is unreachable too.
     *
     *      An unset variable falls back to `ADMIN`, which is already non-zero by the time it is used as a
     *      default, so the only way one of these reads zero is if it was set to zero on purpose. Unlike the
     *      factory — where the struct has no way to say "absent" and zero therefore *means* "use the
     *      admin" — an environment can simply leave a variable out. Zero carries no meaning here, so the
     *      only thing it can be is a mistake.
     */
    function _readAuthorities() internal view returns (Authorities memory authorities) {
        authorities.admin = _requirePresent(vm.envAddress("ADMIN"), "ADMIN");
        authorities.fee = _requirePresent(vm.envOr("FEE_AUTHORITY", authorities.admin), "FEE_AUTHORITY");
        authorities.restriction =
            _requirePresent(vm.envOr("RESTRICTION_AUTHORITY", authorities.admin), "RESTRICTION_AUTHORITY");
        authorities.mint = _requirePresent(vm.envOr("MINT_AUTHORITY", authorities.admin), "MINT_AUTHORITY");
        authorities.seize = _requirePresent(vm.envOr("SEIZE_AUTHORITY", authorities.admin), "SEIZE_AUTHORITY");
        authorities.metadata =
            _requirePresent(vm.envOr("METADATA_AUTHORITY", authorities.admin), "METADATA_AUTHORITY");
        authorities.hook = _requirePresent(vm.envOr("HOOK_AUTHORITY", authorities.admin), "HOOK_AUTHORITY");
    }

    /// @dev Rejects the zero address, naming the variable that supplied it.
    function _requirePresent(address authority, string memory name) internal pure returns (address) {
        require(authority != address(0), string.concat(name, " cannot be the zero address"));
        return authority;
    }

    /**
     * @dev Reads the fee rate at full width and range-checks it before narrowing.
     *
     *      Narrowing first is the trap: `uint16(vm.envUint(...))` turns 65,636 into 100, so a fat-fingered
     *      environment deploys a token with a rate nobody asked for and no error anywhere. The token's own
     *      `setFeeConfig` would have caught a value above the ceiling, but only after the truncation had
     *      already made it look legitimate.
     */
    function _readBasisPoints(ExtendedTokenBase token) internal view returns (uint16) {
        uint256 raw = vm.envUint("FEE_BASIS_POINTS");
        uint256 ceiling = token.MAX_FEE_BASIS_POINTS();
        require(raw <= ceiling, "FEE_BASIS_POINTS exceeds MAX_FEE_BASIS_POINTS");
        return uint16(raw);
    }

    /**
     * @dev Grants each role to its intended holder, then strips the deployer of everything it does not
     *      legitimately keep. `DEFAULT_ADMIN_ROLE` goes last because it is what authorises the other
     *      revocations; dropping it first strands whatever came after it.
     */
    function _distributeRoles(ExtendedTokenBase token, Authorities memory authorities) internal {
        token.grantRole(token.DEFAULT_ADMIN_ROLE(), authorities.admin);
        token.grantRole(token.FEE_CONFIG_ROLE(), authorities.fee);
        token.grantRole(token.RESTRICTION_ROLE(), authorities.restriction);
        token.grantRole(token.MINT_ROLE(), authorities.mint);
        token.grantRole(token.SEIZE_ROLE(), authorities.seize);
        token.grantRole(token.METADATA_ROLE(), authorities.metadata);
        token.grantRole(token.HOOK_CONFIG_ROLE(), authorities.hook);

        address deployer = msg.sender;
        _relinquish(token, token.FEE_CONFIG_ROLE(), deployer, authorities.fee);
        _relinquish(token, token.RESTRICTION_ROLE(), deployer, authorities.restriction);
        _relinquish(token, token.MINT_ROLE(), deployer, authorities.mint);
        _relinquish(token, token.SEIZE_ROLE(), deployer, authorities.seize);
        _relinquish(token, token.METADATA_ROLE(), deployer, authorities.metadata);
        _relinquish(token, token.HOOK_CONFIG_ROLE(), deployer, authorities.hook);
        _relinquish(token, token.DEFAULT_ADMIN_ROLE(), deployer, authorities.admin);
    }

    /// @dev Asserts the distribution actually landed, so a silent regression fails the deployment.
    function _assertRoles(ExtendedTokenBase token, Authorities memory authorities) internal view {
        address deployer = msg.sender;

        _assertHolds(token, token.DEFAULT_ADMIN_ROLE(), authorities.admin, deployer, "DEFAULT_ADMIN");
        _assertHolds(token, token.FEE_CONFIG_ROLE(), authorities.fee, deployer, "FEE_CONFIG");
        _assertHolds(token, token.RESTRICTION_ROLE(), authorities.restriction, deployer, "RESTRICTION");
        _assertHolds(token, token.MINT_ROLE(), authorities.mint, deployer, "MINT");
        _assertHolds(token, token.SEIZE_ROLE(), authorities.seize, deployer, "SEIZE");
        _assertHolds(token, token.METADATA_ROLE(), authorities.metadata, deployer, "METADATA");
        _assertHolds(token, token.HOOK_CONFIG_ROLE(), authorities.hook, deployer, "HOOK_CONFIG");
    }

    function _relinquish(ExtendedTokenBase token, bytes32 role, address deployer, address intended) private {
        if (deployer != intended) token.revokeRole(role, deployer);
    }

    function _assertHolds(
        ExtendedTokenBase token,
        bytes32 role,
        address intended,
        address deployer,
        string memory label
    ) private view {
        // `hasRole(role, address(0))` answers true once the role has been granted to zero, so asking only
        // whether the intended holder holds it would confirm exactly the deployment worth refusing.
        require(intended != address(0), string.concat(label, "_ROLE assigned to the zero address"));
        require(token.hasRole(role, intended), string.concat(label, "_ROLE not held by its authority"));
        if (deployer != intended) {
            require(!token.hasRole(role, deployer), string.concat(label, "_ROLE still held by the deployer"));
        }
    }

    function _logAuthorities(Authorities memory authorities) internal pure {
        console2.log("  admin          ", authorities.admin);
        console2.log("  fee            ", authorities.fee);
        console2.log("  restriction    ", authorities.restriction);
        console2.log("  mint           ", authorities.mint);
        console2.log("  seize          ", authorities.seize);
        console2.log("  metadata       ", authorities.metadata);
        console2.log("  hook           ", authorities.hook);
    }
}

/**
 * @title DeployImmutable
 * @notice Deploys {ExtendedToken}, configures the fee, and hands each authority to a separate address.
 *
 * @dev Redistributing the roles is the part worth copying. The initialiser puts every role on one admin so
 *      that a deployment is usable immediately, but leaving it that way throws away the reason the roles
 *      are separate: an operations key that can pause the token should not also be able to raise the fee,
 *      and neither should be able to grant itself the other.
 *
 *      Environment:
 *        TOKEN_NAME, TOKEN_SYMBOL       strings
 *        ADMIN                          receives DEFAULT_ADMIN_ROLE and can redistribute later; every
 *                                       authority below is rejected if set to the zero address
 *        FEE_VAULT                      collects fees
 *        FEE_BASIS_POINTS               0..MAX_FEE_BASIS_POINTS, range-checked before narrowing
 *        MAXIMUM_FEE                    absolute per-transfer cap, in token units
 *        FEE_AUTHORITY                  optional; defaults to ADMIN
 *        RESTRICTION_AUTHORITY          optional; defaults to ADMIN
 *        MINT_AUTHORITY                 optional; defaults to ADMIN
 *        SEIZE_AUTHORITY                optional; defaults to ADMIN
 *        METADATA_AUTHORITY             optional; defaults to ADMIN
 *        HOOK_AUTHORITY                 optional; defaults to ADMIN
 */
contract DeployImmutable is DeployBase {
    function run() external returns (ExtendedToken token) {
        string memory name = vm.envString("TOKEN_NAME");
        string memory symbol = vm.envString("TOKEN_SYMBOL");
        address feeVault = vm.envAddress("FEE_VAULT");
        uint256 maximumFee = vm.envUint("MAXIMUM_FEE");
        Authorities memory authorities = _readAuthorities();

        vm.startBroadcast();

        token = new ExtendedToken(name, symbol, msg.sender);

        // Configure while the broadcaster still holds every role. No `setFeeExempt` for the vault:
        // `isFeeExempt` already answers true for whichever address is currently the vault, and recording
        // it explicitly would leave the *old* vault exempt forever after a rotation.
        token.setFeeVault(feeVault);
        token.setFeeConfig(_readBasisPoints(token), maximumFee);

        _distributeRoles(token, authorities);

        vm.stopBroadcast();

        _assertRoles(token, authorities);

        console2.log("");
        console2.log("ExtendedToken");
        console2.log("  address        ", address(token));
        console2.log("  behaviorFlags  ", token.behaviorFlags());
        console2.log("  extensions     ", token.extensions().length);
        _logAuthorities(authorities);
        console2.log("");
        console2.log("  Integrators: read behaviorFlags() once and cache it. See docs/INTEGRATION.md.");
    }
}

/**
 * @title DeployUpgradeable
 * @notice Deploys {ExtendedTokenUpgradeable} behind an ERC-1967 proxy.
 *
 * @dev Takes the same environment as {DeployImmutable}, plus `UPGRADE_AUTHORITY` (optional; defaults to
 *      ADMIN) — and, unlike an earlier version of this script, actually reads the rest of them. The
 *      resulting token declares `UPGRADEABLE`, which is a promise to integrators that the upgrade authority
 *      exists, so it is worth pointing that authority at a timelock or a multisig before anyone integrates,
 *      not after.
 */
contract DeployUpgradeable is DeployBase {
    function run() external returns (ExtendedTokenUpgradeable token) {
        string memory name = vm.envString("TOKEN_NAME");
        string memory symbol = vm.envString("TOKEN_SYMBOL");
        address feeVault = vm.envAddress("FEE_VAULT");
        uint256 maximumFee = vm.envUint("MAXIMUM_FEE");
        Authorities memory authorities = _readAuthorities();
        address upgradeAuthority =
            _requirePresent(vm.envOr("UPGRADE_AUTHORITY", authorities.admin), "UPGRADE_AUTHORITY");

        vm.startBroadcast();

        ExtendedTokenUpgradeable implementation = new ExtendedTokenUpgradeable();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(ExtendedTokenUpgradeable.initialize, (name, symbol, msg.sender))
        );
        token = ExtendedTokenUpgradeable(address(proxy));

        token.setFeeVault(feeVault);
        token.setFeeConfig(_readBasisPoints(token), maximumFee);

        // `UPGRADER_ROLE` is not part of the shared set, and has to move before `DEFAULT_ADMIN_ROLE` does.
        token.grantRole(token.UPGRADER_ROLE(), upgradeAuthority);
        if (msg.sender != upgradeAuthority) token.revokeRole(token.UPGRADER_ROLE(), msg.sender);

        _distributeRoles(token, authorities);

        vm.stopBroadcast();

        _assertRoles(token, authorities);
        require(upgradeAuthority != address(0), "UPGRADER_ROLE assigned to the zero address");
        require(token.hasRole(token.UPGRADER_ROLE(), upgradeAuthority), "UPGRADER_ROLE not held");
        if (msg.sender != upgradeAuthority) {
            require(!token.hasRole(token.UPGRADER_ROLE(), msg.sender), "UPGRADER_ROLE still held by the deployer");
        }

        console2.log("");
        console2.log("ExtendedTokenUpgradeable");
        console2.log("  proxy          ", address(proxy));
        console2.log("  implementation ", address(implementation));
        console2.log("  behaviorFlags  ", token.behaviorFlags());
        _logAuthorities(authorities);
        console2.log("  upgrade        ", upgradeAuthority);
        console2.log("");
        console2.log("  An upgrade must not change the extension set. See ExtendedTokenUpgradeable's NatSpec.");
    }
}
