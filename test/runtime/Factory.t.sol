// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

import {ExtendedTokenBase} from "../../src/ExtendedTokenBase.sol";
import {ERC20ExtensionCore} from "../../src/extensions/ERC20ExtensionCore.sol";
import {BehaviorFlags} from "../../src/libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../../src/libraries/ExtensionIds.sol";
import {BERCFactoryV1} from "../../src/runtime/BERCFactoryV1.sol";
import {BERCRuntimeV1} from "../../src/runtime/BERCRuntimeV1.sol";
import {PlainERC20} from "../mocks/PlainERC20.sol";

/**
 * @title FactoryTest
 * @notice Covers what one factory call has to get right so that a deployer never has to.
 *
 * @dev The role handover test earns its place: the same ordering mistake — dropping `DEFAULT_ADMIN_ROLE`
 *      before the roles it authorises revoking — compiled and passed every other test when it was written
 *      in `script/Deploy.s.sol`, and only surfaced when the script was actually run.
 */
contract FactoryTest is Test {
    BERCRuntimeV1 internal runtime;
    BERCFactoryV1 internal factory;

    address internal admin = makeAddr("admin");
    address internal vault = makeAddr("vault");

    function setUp() public {
        runtime = new BERCRuntimeV1();
        factory = new BERCFactoryV1(address(runtime));
    }

    // -----------------------------------------------------------------------------------------------
    // Deployment
    // -----------------------------------------------------------------------------------------------

    function test_DeploysWithEveryCompatibleExtension() public {
        bytes4[] memory ids = new bytes4[](4);
        ids[0] = ExtensionIds.ONCHAIN_METADATA;
        ids[1] = ExtensionIds.TRANSFER_FEE;
        ids[2] = ExtensionIds.TRANSFER_RESTRICTION;
        ids[3] = ExtensionIds.TRANSFER_HOOK;

        BERCRuntimeV1 token = BERCRuntimeV1(_deploy(ids, vault, 250, 1000e18));

        assertEq(token.extensions().length, 4);
        assertEq(
            token.behaviorFlags(),
            BehaviorFlags.FEE_ON_TRANSFER | BehaviorFlags.TRANSFER_HOOK | BehaviorFlags.PAUSABLE
                | BehaviorFlags.BLOCKLIST | BehaviorFlags.MINTABLE | BehaviorFlags.SEIZABLE
        );
        assertEq(token.feeBasisPoints(), 250);
        assertEq(token.maximumFee(), 1000e18);
        assertTrue(token.isFeeExempt(vault), "the vault must not pay a fee into itself");
    }

    /**
     * @dev The vault's exemption follows the role, not the address. Granting it explicitly at deployment
     *      would look identical here and diverge the first time the vault was rotated, leaving an address
     *      that is exempt for no reason anyone can see.
     */
    function test_RotatingTheVaultMovesTheExemptionWithIt() public {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = ExtensionIds.TRANSFER_FEE;
        BERCRuntimeV1 token = BERCRuntimeV1(_deploy(ids, vault, 250, 1000e18));

        address replacement = makeAddr("replacementVault");
        vm.prank(admin);
        token.setFeeVault(replacement);

        assertTrue(token.isFeeExempt(replacement), "the new vault is exempt");
        assertFalse(token.isFeeExempt(vault), "and the old one is not left exempt behind it");
    }

    /**
     * @dev An empty extension set is legitimate — and still does not mean `behaviorFlags() == 0`. Every
     *      token from this base can mint and can burn from any account, so it says so.
     */
    function test_DeploysWithNoExtensions() public {
        BERCRuntimeV1 token = BERCRuntimeV1(_deploy(new bytes4[](0), address(0), 0, 0));

        assertEq(token.extensions().length, 0);
        assertEq(token.behaviorFlags(), BehaviorFlags.MINTABLE | BehaviorFlags.SEIZABLE);
    }

    function test_DeploysNonTransferable() public {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = ExtensionIds.NON_TRANSFERABLE;

        BERCRuntimeV1 token = BERCRuntimeV1(_deploy(ids, address(0), 0, 0));

        assertEq(
            token.behaviorFlags(), BehaviorFlags.NON_TRANSFERABLE | BehaviorFlags.MINTABLE | BehaviorFlags.SEIZABLE
        );
    }

    // -----------------------------------------------------------------------------------------------
    // Rejected requests
    // -----------------------------------------------------------------------------------------------

    function test_RejectsNonTransferableWithFee() public {
        bytes4[] memory ids = new bytes4[](2);
        ids[0] = ExtensionIds.NON_TRANSFERABLE;
        ids[1] = ExtensionIds.TRANSFER_FEE;

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20ExtensionCore.ERC20IncompatibleBehaviors.selector,
                BehaviorFlags.NON_TRANSFERABLE,
                BehaviorFlags.FEE_ON_TRANSFER
            )
        );
        _deploy(ids, vault, 0, 0);
    }

    function test_RejectsNonTransferableWithHook() public {
        bytes4[] memory ids = new bytes4[](2);
        ids[0] = ExtensionIds.NON_TRANSFERABLE;
        ids[1] = ExtensionIds.TRANSFER_HOOK;

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20ExtensionCore.ERC20IncompatibleBehaviors.selector,
                BehaviorFlags.NON_TRANSFERABLE,
                BehaviorFlags.TRANSFER_HOOK
            )
        );
        _deploy(ids, address(0), 0, 0);
    }

    function test_RejectsDuplicateExtension() public {
        bytes4[] memory ids = new bytes4[](2);
        ids[0] = ExtensionIds.TRANSFER_RESTRICTION;
        ids[1] = ExtensionIds.TRANSFER_RESTRICTION;

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20ExtensionCore.ERC20ExtensionAlreadyRegistered.selector, ExtensionIds.TRANSFER_RESTRICTION
            )
        );
        _deploy(ids, address(0), 0, 0);
    }

    function test_RejectsUnknownExtension() public {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = bytes4(0xdeadbeef);

        vm.expectRevert(abi.encodeWithSelector(ExtendedTokenBase.ExtendedTokenUnknownExtension.selector, ids[0]));
        _deploy(ids, address(0), 0, 0);
    }

    /// @dev Silently ignoring the parameters would leave a deployer believing they had configured a fee.
    function test_RejectsFeeParametersWithoutTheFeeExtension() public {
        vm.expectRevert(BERCFactoryV1.BERCFeeConfigWithoutFeeExtension.selector);
        _deploy(new bytes4[](0), vault, 0, 0);
    }

    /// @dev A zero rate would pass the runtime's own check and leave a fee token that cannot collect.
    function test_RejectsTheFeeExtensionWithoutAVault() public {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = ExtensionIds.TRANSFER_FEE;

        vm.expectRevert(BERCFactoryV1.BERCFeeVaultRequired.selector);
        _deploy(ids, address(0), 0, 0);
    }

    function test_RejectsZeroAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(BERCFactoryV1.BERCInvalidAdmin.selector, address(0)));
        factory.deploy(_params(new bytes4[](0), address(0), address(0), 0, 0));
    }

    /// @dev The factory gives up every role before returning, so naming it admin would strand the token.
    function test_RejectsTheFactoryAsAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(BERCFactoryV1.BERCInvalidAdmin.selector, address(factory)));
        factory.deploy(_params(new bytes4[](0), address(factory), address(0), 0, 0));
    }

    function test_RejectsARuntimeWithNoCode() public {
        address notAContract = makeAddr("notAContract");
        vm.expectRevert(abi.encodeWithSelector(BERCFactoryV1.BERCInvalidRuntime.selector, notAContract));
        new BERCFactoryV1(notAContract);
    }

    // -----------------------------------------------------------------------------------------------
    // Role handover
    // -----------------------------------------------------------------------------------------------

    function test_AdminEndsWithEveryRoleAndTheFactoryWithNone() public {
        bytes4[] memory ids = new bytes4[](4);
        ids[0] = ExtensionIds.ONCHAIN_METADATA;
        ids[1] = ExtensionIds.TRANSFER_FEE;
        ids[2] = ExtensionIds.TRANSFER_RESTRICTION;
        ids[3] = ExtensionIds.TRANSFER_HOOK;

        BERCRuntimeV1 token = BERCRuntimeV1(_deploy(ids, vault, 250, 1000e18));

        bytes32[7] memory roles = [
            token.DEFAULT_ADMIN_ROLE(),
            token.MINT_ROLE(),
            token.SEIZE_ROLE(),
            token.METADATA_ROLE(),
            token.FEE_CONFIG_ROLE(),
            token.RESTRICTION_ROLE(),
            token.HOOK_CONFIG_ROLE()
        ];

        for (uint256 i = 0; i < roles.length; ++i) {
            assertTrue(token.hasRole(roles[i], admin), "admin must hold every role");
            assertFalse(token.hasRole(roles[i], address(factory)), "the factory must hold none");
        }
    }

    /**
     * @dev The split happens inside the deployment, not in a follow-up transaction. The window between a
     *      deploy and a separate redistribution is one where a single key holds every role — the state the
     *      split exists to avoid, and where an interrupted deployment would be stranded.
     */
    function test_EachRoleCanBeHandedToItsOwnAuthorityAtCreation() public {
        address feeAuthority = makeAddr("feeAuthority");
        address restrictionAuthority = makeAddr("restrictionAuthority");
        address mintAuthority = makeAddr("mintAuthority");
        address seizeAuthority = makeAddr("seizeAuthority");

        bytes4[] memory ids = new bytes4[](4);
        ids[0] = ExtensionIds.ONCHAIN_METADATA;
        ids[1] = ExtensionIds.TRANSFER_FEE;
        ids[2] = ExtensionIds.TRANSFER_RESTRICTION;
        ids[3] = ExtensionIds.TRANSFER_HOOK;

        BERCRuntimeV1 token = BERCRuntimeV1(
            factory.deploy(
                BERCFactoryV1.TokenParams({
                    name: "Split",
                    symbol: "SPL",
                    admin: admin,
                    authorities: BERCFactoryV1.Authorities({
                        fee: feeAuthority,
                        restriction: restrictionAuthority,
                        mint: mintAuthority,
                        seize: seizeAuthority,
                        metadata: address(0), // falls back to admin
                        hook: address(0)
                    }),
                    extensionIds: ids,
                    feeVault: vault,
                    feeBasisPoints: 250,
                    maximumFee: 1000e18
                })
            )
        );

        assertTrue(token.hasRole(token.FEE_CONFIG_ROLE(), feeAuthority));
        assertTrue(token.hasRole(token.RESTRICTION_ROLE(), restrictionAuthority));
        assertTrue(token.hasRole(token.MINT_ROLE(), mintAuthority));
        assertTrue(token.hasRole(token.SEIZE_ROLE(), seizeAuthority));
        assertTrue(token.hasRole(token.METADATA_ROLE(), admin), "an unset field falls back to admin");
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));

        // And the admin does not silently keep the roles it delegated.
        assertFalse(token.hasRole(token.FEE_CONFIG_ROLE(), admin));
        assertFalse(token.hasRole(token.MINT_ROLE(), admin));
        assertFalse(token.hasRole(token.SEIZE_ROLE(), admin));
        assertFalse(token.hasRole(token.FEE_CONFIG_ROLE(), address(factory)));

        // The point of the split: neither supply key can reach the other's power.
        vm.prank(mintAuthority);
        vm.expectRevert();
        token.burn(admin, 1);

        vm.prank(seizeAuthority);
        vm.expectRevert();
        token.mint(admin, 1);
    }

    function test_TheFactoryCannotConfigureATokenItDeployed() public {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = ExtensionIds.TRANSFER_RESTRICTION;

        BERCRuntimeV1 token = BERCRuntimeV1(_deploy(ids, address(0), 0, 0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(factory), token.RESTRICTION_ROLE()
            )
        );
        vm.prank(address(factory));
        token.setTransfersPaused(true);
    }

    // -----------------------------------------------------------------------------------------------
    // Index and deterministic addresses
    // -----------------------------------------------------------------------------------------------

    function test_IndexRecordsEveryDeployment() public {
        assertEq(factory.tokenCount(), 0);

        address first = _deploy(new bytes4[](0), address(0), 0, 0);
        address second = _deploy(new bytes4[](0), address(0), 0, 0);

        assertEq(factory.tokenCount(), 2);
        assertEq(factory.tokenAt(0), first);
        assertEq(factory.tokenAt(1), second);
        assertTrue(factory.isDeployedToken(first));
        assertTrue(factory.isDeployedToken(second));
        assertFalse(factory.isDeployedToken(address(new PlainERC20("Plain", "PLN"))));
    }

    function test_DeterministicAddressMatchesThePrediction() public {
        bytes32 salt = keccak256("salt");
        address predicted = factory.predictDeterministicAddress(address(this), salt);

        address deployed = factory.deployDeterministic(_params(new bytes4[](0), admin, address(0), 0, 0), salt);

        assertEq(deployed, predicted);
    }

    /// @dev The caller is mixed into the salt, so one deployer cannot occupy another's chosen address.
    function test_TheSameSaltFromTwoDeployersDoesNotCollide() public {
        bytes32 salt = keccak256("shared");
        address other = makeAddr("other");

        address mine = factory.deployDeterministic(_params(new bytes4[](0), admin, address(0), 0, 0), salt);

        vm.prank(other);
        address theirs = factory.deployDeterministic(_params(new bytes4[](0), admin, address(0), 0, 0), salt);

        assertTrue(mine != theirs);
        assertEq(theirs, factory.predictDeterministicAddress(other, salt));
    }

    // -----------------------------------------------------------------------------------------------

    function _params(bytes4[] memory ids, address admin_, address feeVault, uint16 basisPoints, uint256 maximumFee)
        private
        pure
        returns (BERCFactoryV1.TokenParams memory)
    {
        return BERCFactoryV1.TokenParams({
            name: "Runtime Token",
            symbol: "RUN",
            admin: admin_,
            authorities: _noSplit(),
            extensionIds: ids,
            feeVault: feeVault,
            feeBasisPoints: basisPoints,
            maximumFee: maximumFee
        });
    }

    /// @dev All zero, so every role falls back to `admin`.
    function _noSplit() private pure returns (BERCFactoryV1.Authorities memory) {
        return BERCFactoryV1.Authorities({
            fee: address(0),
            restriction: address(0),
            mint: address(0),
            seize: address(0),
            metadata: address(0),
            hook: address(0)
        });
    }

    function _deploy(bytes4[] memory ids, address feeVault, uint16 basisPoints, uint256 maximumFee)
        private
        returns (address)
    {
        return factory.deploy(_params(ids, admin, feeVault, basisPoints, maximumFee));
    }
}
