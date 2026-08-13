// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20ExtensionCore} from "../../src/extensions/ERC20ExtensionCore.sol";
import {IERC20Extensions} from "../../src/interfaces/IERC20Extensions.sol";
import {IERC20NonTransferable} from "../../src/interfaces/IERC20NonTransferable.sol";
import {BehaviorFlags} from "../../src/libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../../src/libraries/ExtensionIds.sol";
import {BERCFactoryV1} from "../../src/runtime/BERCFactoryV1.sol";
import {BERCRuntimeV1} from "../../src/runtime/BERCRuntimeV1.sol";

/**
 * @title RuntimeTest
 * @notice One contract carries every extension, and each token turns on a subset. These tests cover the
 *         two ways that arrangement could go wrong: a module acting on a token that never asked for it,
 *         and a token being configurable into something its own `extensions()` denies.
 */
contract RuntimeTest is Test {
    BERCRuntimeV1 internal runtime;
    BERCFactoryV1 internal factory;

    address internal admin = makeAddr("admin");
    address internal vault = makeAddr("vault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        runtime = new BERCRuntimeV1();
        factory = new BERCFactoryV1(address(runtime));
    }

    // -----------------------------------------------------------------------------------------------
    // Uninstalled modules stay out of the way
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev A token with only metadata installed still inherits the fee, restriction and hook modules'
     *      code. None of them may touch a transfer.
     */
    function test_UninstalledModulesDoNothing() public {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = ExtensionIds.ONCHAIN_METADATA;
        BERCRuntimeV1 token = _deploy(ids, address(0), 0, 0);

        vm.prank(admin);
        token.mint(alice, 1000e18);

        vm.prank(alice);
        token.transfer(bob, 400e18);

        assertEq(token.balanceOf(bob), 400e18, "no fee may be withheld by a module that is not installed");
        assertEq(token.balanceOf(alice), 600e18);
        // The supply powers are always present and always declared; no *extension* behaviour is.
        assertEq(
            token.behaviorFlags(),
            BehaviorFlags.MINTABLE | BehaviorFlags.SEIZABLE,
            "no uninstalled module may declare anything"
        );
    }

    /**
     * @dev `ERC20NonTransferable` reverts unconditionally by design, which would brick every token in a
     *      shared runtime. Its gate is the one place the subset model needs explicit help.
     */
    function test_NonTransferableOnlyBlocksTokensThatInstalledIt() public {
        BERCRuntimeV1 open = _deploy(new bytes4[](0), address(0), 0, 0);

        bytes4[] memory ids = new bytes4[](1);
        ids[0] = ExtensionIds.NON_TRANSFERABLE;
        BERCRuntimeV1 soulbound = _deploy(ids, address(0), 0, 0);

        vm.startPrank(admin);
        open.mint(alice, 1000e18);
        soulbound.mint(alice, 1000e18);
        vm.stopPrank();

        vm.prank(alice);
        open.transfer(bob, 1e18);
        assertEq(open.balanceOf(bob), 1e18, "a token without the module must transfer normally");

        vm.prank(alice);
        vm.expectRevert(IERC20NonTransferable.ERC20TransfersNotSupported.selector);
        soulbound.transfer(bob, 1e18);
    }

    // -----------------------------------------------------------------------------------------------
    // A token cannot be configured into something it does not declare
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev Every setter exists on every token because every module is inherited. Without the installed
     *      check in `_authorizeExtensionConfig`, the admin of a token reporting no fee extension could
     *      give it one, and `extensions()` would go on saying it had none.
     */
    function test_ConfiguringAnUninstalledExtensionReverts() public {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = ExtensionIds.ONCHAIN_METADATA;
        BERCRuntimeV1 token = _deploy(ids, address(0), 0, 0);

        vm.startPrank(admin);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Extensions.ERC20ExtensionNotEnabled.selector, ExtensionIds.TRANSFER_FEE)
        );
        token.setFeeVault(vault);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Extensions.ERC20ExtensionNotEnabled.selector, ExtensionIds.TRANSFER_RESTRICTION
            )
        );
        token.setTransfersPaused(true);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Extensions.ERC20ExtensionNotEnabled.selector, ExtensionIds.TRANSFER_HOOK)
        );
        token.setTransferHook(address(0), 0);

        vm.stopPrank();
    }

    // -----------------------------------------------------------------------------------------------
    // Initialisation
    // -----------------------------------------------------------------------------------------------

    /// @dev An initialised implementation would be a working token that passes no clone check.
    function test_TheImplementationCannotBeInitialised() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        runtime.initialize("Impostor", "IMP", admin, new bytes4[](0));
    }

    function test_ACloneCannotBeInitialisedTwice() public {
        address token = Clones.clone(address(runtime));
        BERCRuntimeV1(token).initialize("Once", "ONE", admin, new bytes4[](0));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        BERCRuntimeV1(token).initialize("Twice", "TWO", alice, new bytes4[](0));
    }

    /// @dev Discovery has to fail loudly before the set is sealed, not answer "no extensions".
    function test_DiscoveryRevertsBeforeInitialisation() public {
        BERCRuntimeV1 bare = BERCRuntimeV1(Clones.clone(address(runtime)));

        vm.expectRevert(ERC20ExtensionCore.ERC20ExtensionSetNotSealed.selector);
        bare.behaviorFlags();

        vm.expectRevert(ERC20ExtensionCore.ERC20ExtensionSetNotSealed.selector);
        bare.hasExtension(ExtensionIds.TRANSFER_FEE);
    }

    // -----------------------------------------------------------------------------------------------
    // Still an ERC-20
    // -----------------------------------------------------------------------------------------------

    function test_AFullyLoadedRuntimeTokenIsStillAPlainERC20() public {
        bytes4[] memory ids = new bytes4[](4);
        ids[0] = ExtensionIds.ONCHAIN_METADATA;
        ids[1] = ExtensionIds.TRANSFER_FEE;
        ids[2] = ExtensionIds.TRANSFER_RESTRICTION;
        ids[3] = ExtensionIds.TRANSFER_HOOK;
        BERCRuntimeV1 token = _deploy(ids, vault, 250, type(uint256).max);

        vm.prank(admin);
        token.mint(alice, 1000e18);

        assertEq(token.name(), "Runtime Token");
        assertEq(token.symbol(), "RUN");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1000e18);

        vm.prank(alice);
        assertTrue(token.approve(bob, 100e18), "approve must return true");
        assertEq(token.allowance(alice, bob), 100e18);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 100e18), "transferFrom must return true");
    }

    /**
     * @dev Drives the whole pipeline on a runtime token — restriction, fee, main leg, hook — plus the
     *      aggregated views. The plumbing a fifth module forced `BERCRuntimeV1` to restate is only real if
     *      something actually walks through it.
     */
    function test_TheFullPipelineRunsOnARuntimeToken() public {
        bytes4[] memory ids = new bytes4[](4);
        ids[0] = ExtensionIds.ONCHAIN_METADATA;
        ids[1] = ExtensionIds.TRANSFER_FEE;
        ids[2] = ExtensionIds.TRANSFER_RESTRICTION;
        ids[3] = ExtensionIds.TRANSFER_HOOK;
        BERCRuntimeV1 token = _deploy(ids, vault, 250, type(uint256).max);

        vm.prank(admin);
        token.mint(alice, 1000e18);

        vm.prank(alice);
        token.transfer(bob, 400e18);

        uint256 fee = (400e18 * 250) / 10_000;
        assertEq(token.balanceOf(bob), 400e18 - fee, "the fee module ran");
        assertEq(token.balanceOf(vault), fee, "and delivered to the vault");
        assertEq(token.computeFee(alice, bob, 400e18), fee, "quoted and charged agree");

        // The aggregated per-account view reaches both overriding modules.
        vm.startPrank(admin);
        token.setFrozen(bob, true);
        token.setFeeExempt(bob, true);
        vm.stopPrank();

        assertTrue(token.accountState(bob).frozen);
        assertTrue(token.accountState(bob).feeExempt);

        // And `extensionData` dispatches across every installed module.
        assertGt(token.extensionData(ExtensionIds.TRANSFER_FEE).length, 0);
        assertGt(token.extensionData(ExtensionIds.TRANSFER_RESTRICTION).length, 0);
        assertGt(token.extensionData(ExtensionIds.ONCHAIN_METADATA).length, 0);
        assertGt(token.extensionData(ExtensionIds.TRANSFER_HOOK).length, 0);
    }

    function test_RuntimeReportsItsVersion() public view {
        assertEq(runtime.RUNTIME_VERSION(), 1);
        assertEq(runtime.RUNTIME_NAME(), "BERC Runtime");
    }

    // -----------------------------------------------------------------------------------------------

    function _deploy(bytes4[] memory ids, address feeVault, uint16 basisPoints, uint256 maximumFee)
        private
        returns (BERCRuntimeV1)
    {
        return BERCRuntimeV1(
            factory.deploy(
                BERCFactoryV1.TokenParams({
                    name: "Runtime Token",
                    symbol: "RUN",
                    admin: admin,
                    authorities: BERCFactoryV1.Authorities(
                        address(0), address(0), address(0), address(0), address(0), address(0)
                    ),
                    extensionIds: ids,
                    feeVault: feeVault,
                    feeBasisPoints: basisPoints,
                    maximumFee: maximumFee
                })
            )
        );
    }
}
