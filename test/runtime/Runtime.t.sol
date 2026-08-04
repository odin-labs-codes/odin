// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Test} from "forge-std/Test.sol";

import {ExtendedTokenBase} from "../../src/ExtendedTokenBase.sol";
import {ERC20ExtensionCore} from "../../src/extensions/ERC20ExtensionCore.sol";
import {IERC20Extensions} from "../../src/interfaces/IERC20Extensions.sol";
import {IERC20NonTransferable} from "../../src/interfaces/IERC20NonTransferable.sol";
import {BehaviorFlags} from "../../src/libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../../src/libraries/ExtensionIds.sol";
import {BERCRuntimeV1} from "../../src/runtime/BERCRuntimeV1.sol";

contract RuntimeTest is Test {
    BERCRuntimeV1 internal runtime;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        runtime = new BERCRuntimeV1();
    }

    function _token(bytes4[] memory ids) private returns (BERCRuntimeV1 token) {
        token = _clone();
        token.initialize("Token", "TKN", admin, ids);
    }

    /// @dev Cloning is a separate step in the failure tests: `expectRevert` applies to the very next call,
    ///      and that has to be `initialize` rather than the `create` behind `Clones.clone`.
    function _clone() private returns (BERCRuntimeV1) {
        return BERCRuntimeV1(Clones.clone(address(runtime)));
    }

    function _ids(bytes4 a) private pure returns (bytes4[] memory ids) {
        ids = new bytes4[](1);
        ids[0] = a;
    }

    function test_AnEmptySetStillDeclaresMintAndSeize() public {
        BERCRuntimeV1 token = _token(new bytes4[](0));

        assertEq(token.extensions().length, 0);
        assertEq(token.behaviorFlags(), BehaviorFlags.MINTABLE | BehaviorFlags.SEIZABLE);
    }

    function test_AnEmptySetTransfersLikeAPlainErc20() public {
        BERCRuntimeV1 token = _token(new bytes4[](0));

        vm.prank(admin);
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.transfer(bob, 40e18);

        assertEq(token.balanceOf(bob), 40e18);
    }

    function test_ASubsetIsInstalledInTheOrderAsked() public {
        bytes4[] memory ids = new bytes4[](2);
        ids[0] = ExtensionIds.TRANSFER_RESTRICTION;
        ids[1] = ExtensionIds.ONCHAIN_METADATA;

        BERCRuntimeV1 token = _token(ids);

        assertEq(token.extensions()[0], ExtensionIds.TRANSFER_RESTRICTION);
        assertEq(token.extensions()[1], ExtensionIds.ONCHAIN_METADATA);
        assertFalse(token.hasExtension(ExtensionIds.TRANSFER_FEE));
    }

    function test_NonTransferableAppliesOnlyToTheTokensThatAskedForIt() public {
        BERCRuntimeV1 soulbound = _token(_ids(ExtensionIds.NON_TRANSFERABLE));
        BERCRuntimeV1 ordinary = _token(new bytes4[](0));

        vm.startPrank(admin);
        soulbound.mint(alice, 10e18);
        ordinary.mint(alice, 10e18);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(IERC20NonTransferable.ERC20TransfersNotSupported.selector);
        soulbound.transfer(bob, 1e18);

        vm.prank(alice);
        ordinary.transfer(bob, 1e18);
        assertEq(ordinary.balanceOf(bob), 1e18);
    }

    function test_RevertWhen_ConfiguringAnExtensionTheTokenLacks() public {
        BERCRuntimeV1 token = _token(_ids(ExtensionIds.ONCHAIN_METADATA));

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Extensions.ERC20ExtensionNotEnabled.selector, ExtensionIds.TRANSFER_FEE)
        );
        vm.prank(admin);
        token.setFeeVault(alice);
    }

    function test_RevertWhen_TheSetContradictsItself() public {
        bytes4[] memory ids = new bytes4[](2);
        ids[0] = ExtensionIds.NON_TRANSFERABLE;
        ids[1] = ExtensionIds.TRANSFER_FEE;

        BERCRuntimeV1 token = _clone();

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20ExtensionCore.ERC20IncompatibleBehaviors.selector,
                BehaviorFlags.NON_TRANSFERABLE,
                BehaviorFlags.FEE_ON_TRANSFER
            )
        );
        token.initialize("Token", "TKN", admin, ids);
    }

    function test_RevertWhen_AnUnknownExtensionIsRequested() public {
        bytes4 nonsense = bytes4(keccak256("erc20.extension.notARealExtension"));
        BERCRuntimeV1 token = _clone();

        vm.expectRevert(abi.encodeWithSelector(ExtendedTokenBase.ExtendedTokenUnknownExtension.selector, nonsense));
        token.initialize("Token", "TKN", admin, _ids(nonsense));
    }

    function test_RevertWhen_AnExtensionIsRequestedTwice() public {
        bytes4[] memory ids = new bytes4[](2);
        ids[0] = ExtensionIds.TRANSFER_FEE;
        ids[1] = ExtensionIds.TRANSFER_FEE;

        BERCRuntimeV1 token = _clone();

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20ExtensionCore.ERC20ExtensionAlreadyRegistered.selector, ExtensionIds.TRANSFER_FEE
            )
        );
        token.initialize("Token", "TKN", admin, ids);
    }

    function test_AnUninitialisedCloneRevertsRatherThanReportingNoExtensions() public {
        BERCRuntimeV1 inert = _clone();

        // "Unknown" and "none" are different answers, and this is the one that says unknown.
        vm.expectRevert(ERC20ExtensionCore.ERC20ExtensionSetNotSealed.selector);
        inert.extensions();

        vm.expectRevert(ERC20ExtensionCore.ERC20ExtensionSetNotSealed.selector);
        inert.behaviorFlags();
    }

    function test_RevertWhen_InitialisingTwice() public {
        BERCRuntimeV1 token = _token(new bytes4[](0));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize("Again", "AGN", admin, new bytes4[](0));
    }

    function test_RevertWhen_InitialisingTheRuntimeItself() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        runtime.initialize("Decoy", "DEC", admin, new bytes4[](0));
    }

    function test_TheRuntimeNamesItself() public view {
        assertEq(runtime.RUNTIME_NAME(), "BERC Runtime");
        assertEq(runtime.RUNTIME_VERSION(), 1);
    }
}
