// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ExtendedTokenBase} from "./ExtendedTokenBase.sol";
import {BehaviorFlags} from "./libraries/BehaviorFlags.sol";

/**
 * @title ExtendedTokenUpgradeable
 * @notice The same assembly as {ExtendedToken}, behind a UUPS proxy, and honest about it.
 *
 * @dev ## `UPGRADEABLE` is declared, not hidden
 *
 *      Upgradeability is the behaviour that subsumes every other one: a token whose code can be replaced can
 *      acquire a fee, a pause, or a hook it never declared. This contract sets `BehaviorFlags.UPGRADEABLE`
 *      in its initialiser, so an integrator reading `behaviorFlags()` learns in the same call that the rest
 *      of the word is only as durable as the upgrade authority. A framework built on declaring behaviour
 *      cannot leave that one out.
 *
 *      ## The constraint an upgrade must respect
 *
 *      **An upgrade must not change the extension set.** Registration happens in the initialiser, which
 *      cannot run twice, so the registry keeps whatever the first implementation wrote. A new implementation
 *      that inherited an additional module would run that module's transfer phases while `extensions()` and
 *      `behaviorFlags()` continued to report the old set — undeclared behaviour, which is the one failure
 *      this framework exists to prevent. Removing a module is equally wrong in the other direction.
 *
 *      Nothing on chain can enforce this, because the proxy cannot inspect the module set of an
 *      implementation it has not yet delegated into. It is a governance obligation, and `UPGRADEABLE` is the
 *      warning that the obligation exists.
 *
 *      ## Storage
 *
 *      Every module keeps its state in its own ERC-7201 namespace, so a later implementation may add fields
 *      to any module's struct, or add modules in any position in the inheritance list, without moving
 *      anything already written.
 */
contract ExtendedTokenUpgradeable is ExtendedTokenBase, UUPSUpgradeable {
    /// @notice Authorises implementation upgrades. Deliberately separate from `DEFAULT_ADMIN_ROLE`.
    bytes32 public constant UPGRADER_ROLE = keccak256("berc.role.UPGRADER");

    /// @dev The implementation is never initialised; only the proxy's storage is.
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialises the proxy.
     * @param admin Receives every role, including {UPGRADER_ROLE}. Expected to redistribute them.
     */
    function initialize(string memory name_, string memory symbol_, address admin) external initializer {
        __ExtendedTokenBase_init(name_, symbol_, admin, _defaultExtensions());
        __UUPSUpgradeable_init();

        _grantRole(UPGRADER_ROLE, admin);

        // Declared before sealing, so it is covered by the same checks as the modules' declarations.
        _declareBehavior(BehaviorFlags.UPGRADEABLE);
        _sealExtensions();
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyRole(UPGRADER_ROLE) {}
}
