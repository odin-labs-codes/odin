// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IERC20TransferFee} from "../src/interfaces/IERC20TransferFee.sol";
import {ExtensionIds} from "../src/libraries/ExtensionIds.sol";

import {BaseTest} from "./BaseTest.sol";

contract TransferFeeTest is BaseTest {
    function test_NoFeeByDefault() public {
        vm.prank(alice);
        token.transfer(bob, 100e18);

        assertEq(token.balanceOf(bob), INITIAL_BALANCE + 100e18);
        assertEq(token.balanceOf(vault), 0);
    }

    function test_FeeIsWithheldFromTheAmount() public {
        _setFee(100); // 1%

        vm.prank(alice);
        token.transfer(bob, 100e18);

        assertEq(token.balanceOf(bob), INITIAL_BALANCE + 99e18);
        assertEq(token.balanceOf(vault), 1e18);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 100e18);
    }

    function test_ComputeFeeMatchesWhatTheTransferWithholds() public {
        _setFee(250);

        uint256 quoted = token.computeFee(alice, bob, 777e18);
        uint256 before = token.balanceOf(bob);

        vm.prank(alice);
        token.transfer(bob, 777e18);

        assertEq(token.balanceOf(bob) - before, 777e18 - quoted);
    }

    function testFuzz_ComputeFeeMatchesWhatTheTransferWithholds(uint16 basisPoints, uint256 amount) public {
        basisPoints = uint16(bound(basisPoints, 0, token.MAX_FEE_BASIS_POINTS()));
        amount = bound(amount, 0, INITIAL_BALANCE);
        _setFee(basisPoints);

        uint256 quoted = token.computeFee(alice, bob, amount);
        uint256 before = token.balanceOf(bob);

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(bob) - before, amount - quoted);
    }

    function test_FeeRoundsInTheSendersFavour() public {
        _setFee(1); // 0.01%

        // 999 * 1 / 10_000 floors to zero.
        assertEq(token.computeFee(alice, bob, 9_999), 0);
    }

    function test_TheFeeLegGetsItsOwnTransferEvent() public {
        _setFee(100);

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, vault, 1e18);

        vm.prank(alice);
        token.transfer(bob, 100e18);
    }

    function test_FeeCollectedEventCarriesTheRealRecipient() public {
        _setFee(100);

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20TransferFee.TransferFeeCollected(alice, bob, 1e18);

        vm.prank(alice);
        token.transfer(bob, 100e18);
    }

    function test_SenderHoldingExactlyTheAmountSucceeds() public {
        _setFee(100);

        vm.prank(admin);
        token.mint(carol, 100e18);

        vm.prank(carol);
        token.transfer(bob, 100e18);

        assertEq(token.balanceOf(carol), 0);
    }

    function test_FeeDeclaresFeeOnTransfer() public view {
        assertTrue(token.behaviorFlags() & (1 << 0) != 0);
    }

    function test_ExtensionDataReportsRateAndVault() public {
        _setFee(300);

        (uint16 basisPoints, address reportedVault) =
            abi.decode(token.extensionData(ExtensionIds.TRANSFER_FEE), (uint16, address));

        assertEq(basisPoints, 300);
        assertEq(reportedVault, vault);
    }

    function test_RevertWhen_RateIsAboveTheImmutableCeiling() public {
        uint16 tooHigh = token.MAX_FEE_BASIS_POINTS() + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferFee.ERC20FeeBasisPointsTooHigh.selector, tooHigh, token.MAX_FEE_BASIS_POINTS()
            )
        );
        vm.prank(admin);
        token.setFeeConfig(tooHigh);
    }

    function test_RevertWhen_VaultIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20TransferFee.ERC20InvalidFeeVault.selector, address(0)));
        vm.prank(admin);
        token.setFeeVault(address(0));
    }

    function test_RevertWhen_CallerLacksTheFeeRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, token.FEE_CONFIG_ROLE()
            )
        );
        vm.prank(alice);
        token.setFeeConfig(100);
    }
}
