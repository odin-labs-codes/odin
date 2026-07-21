// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExtendedToken} from "../src/ExtendedToken.sol";
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
        _setFee(100, type(uint256).max); // 1%

        vm.prank(alice);
        token.transfer(bob, 100e18);

        assertEq(token.balanceOf(bob), INITIAL_BALANCE + 99e18);
        assertEq(token.balanceOf(vault), 1e18);
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 100e18);
    }

    function test_ComputeFeeMatchesWhatTheTransferWithholds() public {
        _setFee(250, type(uint256).max);

        uint256 quoted = token.computeFee(alice, bob, 777e18);
        uint256 before = token.balanceOf(bob);

        vm.prank(alice);
        token.transfer(bob, 777e18);

        assertEq(token.balanceOf(bob) - before, 777e18 - quoted);
    }

    function testFuzz_ComputeFeeMatchesWhatTheTransferWithholds(uint16 basisPoints, uint256 amount) public {
        basisPoints = uint16(bound(basisPoints, 0, token.MAX_FEE_BASIS_POINTS()));
        amount = bound(amount, 0, INITIAL_BALANCE);
        _setFee(basisPoints, type(uint256).max);

        uint256 quoted = token.computeFee(alice, bob, amount);
        uint256 before = token.balanceOf(bob);

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(bob) - before, amount - quoted);
    }

    function test_FeeRoundsInTheSendersFavour() public {
        _setFee(1, type(uint256).max); // 0.01%

        // 999 * 1 / 10_000 floors to zero.
        assertEq(token.computeFee(alice, bob, 9_999), 0);
    }

    function test_TheFeeLegGetsItsOwnTransferEvent() public {
        _setFee(100, type(uint256).max);

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, vault, 1e18);

        vm.prank(alice);
        token.transfer(bob, 100e18);
    }

    function test_FeeCollectedEventCarriesTheRealRecipient() public {
        _setFee(100, type(uint256).max);

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20TransferFee.TransferFeeCollected(alice, bob, 1e18);

        vm.prank(alice);
        token.transfer(bob, 100e18);
    }

    function test_SenderHoldingExactlyTheAmountSucceeds() public {
        _setFee(100, type(uint256).max);

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
        _setFee(300, type(uint256).max);

        (uint16 basisPoints, uint256 cap, address reportedVault) =
            abi.decode(token.extensionData(ExtensionIds.TRANSFER_FEE), (uint16, uint256, address));

        assertEq(basisPoints, 300);
        assertEq(cap, type(uint256).max);
        assertEq(reportedVault, vault);
    }

    function test_MintAndBurnAreNeverCharged() public {
        _setFee(1_000, type(uint256).max);

        vm.startPrank(admin);
        token.mint(carol, 100e18);
        assertEq(token.balanceOf(carol), 100e18);

        token.burn(carol, 100e18);
        vm.stopPrank();

        assertEq(token.balanceOf(carol), 0);
        assertEq(token.balanceOf(vault), 0);
        assertEq(token.computeFee(address(0), carol, 100e18), 0);
        assertEq(token.computeFee(carol, address(0), 100e18), 0);
    }

    function test_ExemptSenderPaysNothing() public {
        _setFee(100, type(uint256).max);
        vm.prank(admin);
        token.setFeeExempt(alice, true);

        vm.prank(alice);
        token.transfer(bob, 100e18);

        assertEq(token.balanceOf(bob), INITIAL_BALANCE + 100e18);
        assertEq(token.balanceOf(vault), 0);
    }

    function test_ExemptRecipientPaysNothingEither() public {
        _setFee(100, type(uint256).max);
        vm.prank(admin);
        token.setFeeExempt(bob, true);

        assertEq(token.computeFee(alice, bob, 100e18), 0);
    }

    function test_RevokingAnExemptionRestoresTheFee() public {
        _setFee(100, type(uint256).max);
        vm.startPrank(admin);
        token.setFeeExempt(alice, true);
        token.setFeeExempt(alice, false);
        vm.stopPrank();

        assertEq(token.computeFee(alice, bob, 100e18), 1e18);
    }

    function test_TheVaultIsExemptWithoutBeingListed() public {
        _setFee(100, type(uint256).max);

        assertTrue(token.isFeeExempt(vault));
        assertEq(token.computeFee(vault, alice, 100e18), 0);
    }

    function test_RotatingTheVaultMovesTheImplicitExemption() public {
        _setFee(100, type(uint256).max);

        vm.prank(admin);
        token.setFeeVault(carol);

        assertTrue(token.isFeeExempt(carol));
        assertFalse(token.isFeeExempt(vault));
    }

    function test_ExactOutDeliversTheAskedAmount() public {
        _setFee(100, type(uint256).max);

        vm.prank(alice);
        uint256 amountIn = token.transferExactOut(bob, 99e18);

        assertEq(amountIn, 100e18);
        assertEq(token.balanceOf(bob), INITIAL_BALANCE + 99e18);
    }

    function test_ExactOutQuoteMatchesTheTransfer() public {
        _setFee(100, type(uint256).max);

        uint256 quoted = token.computeAmountInForExactOut(alice, bob, 99e18);

        vm.prank(alice);
        assertEq(token.transferExactOut(bob, 99e18), quoted);
    }

    function test_ExactOutSpendsTheGrossAllowance() public {
        _setFee(100, type(uint256).max);

        vm.prank(alice);
        token.approve(carol, 100e18);

        vm.prank(carol);
        token.transferFromExactOut(alice, bob, 99e18);

        assertEq(token.allowance(alice, carol), 0);
    }

    function test_ExactOutIsTheIdentityWithNoFee() public view {
        assertEq(token.computeAmountInForExactOut(alice, bob, 123e18), 123e18);
    }

    function test_CapTakesOverFromTheRate() public {
        _setFee(1_000, 5e18); // 10%, capped at 5 tokens

        assertEq(token.computeFee(alice, bob, 10e18), 1e18);
        assertEq(token.computeFee(alice, bob, 1_000e18), 5e18);
        assertEq(token.maximumFee(), 5e18);
    }

    function test_MaximumFeeIsZeroWhileTheRateIsZero() public {
        _setFee(0, 5e18);

        assertEq(token.maximumFee(), 0);
        assertEq(token.computeFee(alice, bob, 1_000e18), 0);
    }

    function testFuzz_FeeNeverExceedsTheCap(uint256 amount) public {
        _setFee(1_000, 5e18);
        amount = bound(amount, 0, INITIAL_BALANCE);

        assertLe(token.computeFee(alice, bob, amount), 5e18);
    }

    function test_RevertWhen_RateIsAboveTheImmutableCeiling() public {
        uint16 tooHigh = token.MAX_FEE_BASIS_POINTS() + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20TransferFee.ERC20FeeBasisPointsTooHigh.selector, tooHigh, token.MAX_FEE_BASIS_POINTS()
            )
        );
        vm.prank(admin);
        token.setFeeConfig(tooHigh, type(uint256).max);
    }

    function test_RevertWhen_RateIsSetWithNoVault() public {
        ExtendedToken fresh = new ExtendedToken("Fresh", "FRS", admin);

        vm.expectRevert(IERC20TransferFee.ERC20FeeVaultNotSet.selector);
        vm.prank(admin);
        fresh.setFeeConfig(100, type(uint256).max);
    }

    function test_ZeroRateIsAcceptedWithNoVault() public {
        ExtendedToken fresh = new ExtendedToken("Fresh", "FRS", admin);

        vm.prank(admin);
        fresh.setFeeConfig(0, 0);

        assertEq(fresh.feeBasisPoints(), 0);
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
        token.setFeeConfig(100, type(uint256).max);
    }
}
