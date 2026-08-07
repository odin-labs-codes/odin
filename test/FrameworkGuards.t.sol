// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ExtendedToken} from "../src/ExtendedToken.sol";
import {ExtendedTokenBase} from "../src/ExtendedTokenBase.sol";
import {ERC20ExtensionCore} from "../src/extensions/ERC20ExtensionCore.sol";
import {ExtensionIds} from "../src/libraries/ExtensionIds.sol";
import {
    DeclareAfterSealToken,
    DoubleRegisterToken,
    DoubleSealToken,
    OverchargingFeeToken,
    RegisterAfterSealToken,
    UnknownFlagToken
} from "./mocks/BadAssemblies.sol";

/**
 * @title FrameworkGuardsTest
 * @notice The guard rails that only a third party assembling their own token can trip.
 *
 * @dev None of these are reachable from {ExtendedToken}, which is precisely why they need tests. This is a
 *      framework: the interesting failure mode is not "our token misbehaves" but "somebody else's token,
 *      built from these modules, misbehaves in a way that still reports itself as well-formed". Every one
 *      of these fails loudly at deployment rather than quietly at the first transfer.
 */
contract FrameworkGuardsTest is Test {
    function test_RevertWhen_ModuleIsRegisteredTwice() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20ExtensionCore.ERC20ExtensionAlreadyRegistered.selector, ExtensionIds.TRANSFER_FEE
            )
        );
        new DoubleRegisterToken();
    }

    function test_RevertWhen_ModuleIsRegisteredAfterSealing() public {
        vm.expectRevert(ERC20ExtensionCore.ERC20ExtensionSetSealed.selector);
        new RegisterAfterSealToken();
    }

    function test_RevertWhen_SealedTwice() public {
        vm.expectRevert(ERC20ExtensionCore.ERC20ExtensionSetSealed.selector);
        new DoubleSealToken();
    }

    function test_RevertWhen_BehaviourIsDeclaredAfterSealing() public {
        vm.expectRevert(ERC20ExtensionCore.ERC20ExtensionSetSealed.selector);
        new DeclareAfterSealToken();
    }

    function test_RevertWhen_AnUnassignedBehaviourBitIsDeclared() public {
        vm.expectRevert(
            abi.encodeWithSelector(ERC20ExtensionCore.ERC20UnknownBehaviorFlag.selector, uint256(1) << 200)
        );
        new UnknownFlagToken();
    }

    /// @dev A fee module cannot take more than the transfer carries, whatever arithmetic it used to get
    ///      there. The token deploys — the mistake is not visible at construction — and then every transfer
    ///      fails with a named error instead of an arithmetic panic.
    function test_RevertWhen_AFeeModuleChargesMoreThanTheTransfer() public {
        OverchargingFeeToken overcharging = new OverchargingFeeToken();
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        overcharging.mint(alice, 1000e18);

        vm.expectRevert(abi.encodeWithSelector(ERC20ExtensionCore.ERC20FeeExceedsAmount.selector, 100e18 + 1, 100e18));
        vm.prank(alice);
        overcharging.transfer(bob, 100e18);
    }

    /// @dev Mint and burn skip the fee phase entirely, so even a broken fee module cannot touch supply.
    function test_SupplyChangesBypassTheFeePhaseEntirely() public {
        OverchargingFeeToken overcharging = new OverchargingFeeToken();
        address alice = makeAddr("alice");

        overcharging.mint(alice, 1000e18);
        assertEq(overcharging.balanceOf(alice), 1000e18);
        assertEq(overcharging.totalSupply(), 1000e18);
    }

    function test_RevertWhen_AdminIsTheZeroAddress() public {
        vm.expectRevert(ExtendedTokenBase.ExtendedTokenInvalidAdmin.selector);
        new ExtendedToken("No Admin", "NOAD", address(0));
    }

    /**
     * @dev `MINTABLE` and `SEIZABLE` are declared as two separate powers, so two separate roles have to
     *      back them. A single role covering both would make the flag word finer-grained than the
     *      authorities behind it — an integrator reading two bits would be told less than the bits imply.
     */
    function test_MintAndSeizeAreSeparateAuthorities() public {
        address admin = makeAddr("admin");
        address minter = makeAddr("minter");
        address seizer = makeAddr("seizer");
        address alice = makeAddr("alice");

        ExtendedToken token = new ExtendedToken("Split", "SPL", admin);

        vm.startPrank(admin);
        token.grantRole(token.MINT_ROLE(), minter);
        token.grantRole(token.SEIZE_ROLE(), seizer);
        token.revokeRole(token.MINT_ROLE(), admin);
        token.revokeRole(token.SEIZE_ROLE(), admin);
        vm.stopPrank();

        vm.prank(minter);
        token.mint(alice, 1000e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, minter, token.SEIZE_ROLE()
            )
        );
        vm.prank(minter);
        token.burn(alice, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, seizer, token.MINT_ROLE()
            )
        );
        vm.prank(seizer);
        token.mint(alice, 1);

        vm.prank(seizer);
        token.burn(alice, 1000e18);
        assertEq(token.totalSupply(), 0, "the seize authority settles the balance the mint authority created");
    }
}
