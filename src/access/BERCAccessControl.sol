// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IBERCAccessControl} from "../interfaces/IBERCAccessControl.sol";

/**
 * @title BERCAccessControl
 * @notice Adds an irreversible administration burn to OpenZeppelin role-based access control.
 *
 * @dev Burning is stronger than merely renouncing `DEFAULT_ADMIN_ROLE`. A deployment may have granted
 *      that role to more than one account, and a remaining administrator could otherwise restore any
 *      authority. Once burned, the public grant and administrator-driven revoke paths are disabled for
 *      everyone. Existing operational authorities keep working until each holder calls `renounceRole` or
 *      {renounceAllRoles}; self-renunciation deliberately remains available forever.
 *
 *      State uses its own ERC-7201 namespace so adding this base does not move any existing module's slots.
 *      An upgradeable assembly can replace this logic, so its upgrade authority must also be renounced
 *      before the burn can be treated as code-level immutability.
 */
abstract contract BERCAccessControl is AccessControlUpgradeable, IBERCAccessControl {
    /// @custom:storage-location erc7201:berc.storage.AccessControlBurn
    struct BercAccessControlStorage {
        bool adminPrivilegesBurned;
    }

    // keccak256(abi.encode(uint256(keccak256("berc.storage.AccessControlBurn")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BERC_ACCESS_CONTROL_STORAGE_LOCATION =
        0x0e1d485d823a9719e7e6ecc31e2462cfee7fe832800ae1f2c3bdb2162a674800;

    function _getBERCAccessControlStorage() private pure returns (BercAccessControlStorage storage $) {
        assembly {
            $.slot := BERC_ACCESS_CONTROL_STORAGE_LOCATION
        }
    }

    /// @inheritdoc IBERCAccessControl
    function adminPrivilegesBurned() public view virtual returns (bool) {
        return _getBERCAccessControlStorage().adminPrivilegesBurned;
    }

    /// @inheritdoc IBERCAccessControl
    function burnAdminPrivileges() external virtual {
        BercAccessControlStorage storage $ = _getBERCAccessControlStorage();
        if ($.adminPrivilegesBurned) revert BERCAdminPrivilegesAlreadyBurned();
        _checkRole(DEFAULT_ADMIN_ROLE);

        address account = _msgSender();

        _revokeRole(DEFAULT_ADMIN_ROLE, account);
        $.adminPrivilegesBurned = true;

        emit AdminPrivilegesBurned(account);
    }

    /// @inheritdoc IBERCAccessControl
    function renounceAllRoles() external virtual {
        address account = _msgSender();
        _renounceManagedRoles(account);
        _revokeRole(DEFAULT_ADMIN_ROLE, account);

        emit AllRolesRenounced(account);
    }

    /**
     * @inheritdoc AccessControlUpgradeable
     * @dev Hiding effective `DEFAULT_ADMIN_ROLE` membership after the burn also closes any management
     *      function a derived assembly protects with `onlyRole(DEFAULT_ADMIN_ROLE)` directly.
     */
    function hasRole(bytes32 role, address account)
        public
        view
        virtual
        override(AccessControlUpgradeable, IAccessControl)
        returns (bool)
    {
        if (role == DEFAULT_ADMIN_ROLE && adminPrivilegesBurned()) return false;
        return super.hasRole(role, account);
    }

    /// @inheritdoc AccessControlUpgradeable
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        if (adminPrivilegesBurned()) revert BERCAdminPrivilegesBurned();
        super.grantRole(role, account);
    }

    /// @inheritdoc AccessControlUpgradeable
    function revokeRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        if (adminPrivilegesBurned()) revert BERCAdminPrivilegesBurned();
        super.revokeRole(role, account);
    }

    /// @dev Implementations revoke every operational role they define. Upgradeable variants extend it.
    function _renounceManagedRoles(address account) internal virtual;

    /// @inheritdoc AccessControlUpgradeable
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IBERCAccessControl).interfaceId || super.supportsInterface(interfaceId);
    }
}
