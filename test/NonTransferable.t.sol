// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ERC20NonTransferable} from "../src/extensions/ERC20NonTransferable.sol";
import {IERC20NonTransferable} from "../src/interfaces/IERC20NonTransferable.sol";
import {BehaviorFlags} from "../src/libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../src/libraries/ExtensionIds.sol";

/// @dev `ExtendedToken` cannot carry this module — `NON_TRANSFERABLE` contradicts both `FEE_ON_TRANSFER`
///      and `TRANSFER_HOOK`, so an assembly with all of them reverts in its own constructor. This is the
///      smallest assembly that can hold it.
contract SoulboundToken is ERC20NonTransferable {
    constructor(string memory name_, string memory symbol_) {
        _init(name_, symbol_);
        _disableInitializers();
    }

    function _init(string memory name_, string memory symbol_) private initializer {
        __ERC20_init(name_, symbol_);
        __ERC20ExtensionCore_init();
        __ERC20NonTransferable_init();
        _sealExtensions();
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function burn(address from, uint256 value) external {
        _burn(from, value);
    }

    function _authorizeExtensionConfig(bytes4) internal view virtual override {}
}

contract NonTransferableTest is Test {
    SoulboundToken internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new SoulboundToken("Soulbound", "SBT");
        token.mint(alice, 100e18);
    }

    function test_MintingWorks() public view {
        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_BurningWorks() public {
        token.burn(alice, 40e18);

        assertEq(token.balanceOf(alice), 60e18);
    }

    function test_RevertWhen_Transferring() public {
        vm.expectRevert(IERC20NonTransferable.ERC20TransfersNotSupported.selector);
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    function test_RevertWhen_TransferringFrom() public {
        vm.prank(alice);
        token.approve(bob, 1e18);

        vm.expectRevert(IERC20NonTransferable.ERC20TransfersNotSupported.selector);
        vm.prank(bob);
        token.transferFrom(alice, bob, 1e18);
    }

    function test_RevertWhen_TransferringToSelf() public {
        vm.expectRevert(IERC20NonTransferable.ERC20TransfersNotSupported.selector);
        vm.prank(alice);
        token.transfer(alice, 1e18);
    }

    function test_ApproveStillWorks() public {
        vm.prank(alice);
        token.approve(bob, 5e18);

        // An allowance on a token that cannot move is harmless, and wallets set one before transferring.
        assertEq(token.allowance(alice, bob), 5e18);
    }

    function test_TheExtensionIsDiscoverable() public view {
        assertTrue(token.hasExtension(ExtensionIds.NON_TRANSFERABLE));
        assertEq(token.extensions().length, 1);
    }

    function test_NonTransferableIsDeclared() public view {
        assertEq(token.behaviorFlags(), BehaviorFlags.NON_TRANSFERABLE);
    }

    function test_ExtensionDataIsEmptyRatherThanReverting() public view {
        assertEq(token.extensionData(ExtensionIds.NON_TRANSFERABLE).length, 0);
    }
}
