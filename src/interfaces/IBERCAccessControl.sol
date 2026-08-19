// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title IBERCAccessControl
 * @notice One-way administration burn and atomic self-renunciation for BERC role assemblies.
 */
interface IBERCAccessControl is IAccessControl {
    /// @notice Role administration has been disabled permanently.
    event AdminPrivilegesBurned(address indexed account);

    /// @notice `account` gave up every BERC role it held in one transaction.
    event AllRolesRenounced(address indexed account);

    /// @notice Role administration was already burned and cannot be used again.
    error BERCAdminPrivilegesAlreadyBurned();

    /// @notice Grants and administrator-driven revocations are disabled after the burn.
    error BERCAdminPrivilegesBurned();

    /// @notice Whether grants and administrator-driven revocations are permanently disabled.
    function adminPrivilegesBurned() external view returns (bool);

    /**
     * @notice Permanently disables `grantRole` and `revokeRole`, and removes the caller's admin role.
     * @dev Existing operational role holders keep their roles and may still give them up themselves.
     */
    function burnAdminPrivileges() external;

    /// @notice Gives up every built-in role held by the caller, including `DEFAULT_ADMIN_ROLE`.
    function renounceAllRoles() external;
}
