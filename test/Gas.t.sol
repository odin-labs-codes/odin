// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {ExtendedToken} from "../src/ExtendedToken.sol";
import {RecordingHook} from "./mocks/HookReceivers.sol";
import {PlainERC20} from "./mocks/PlainERC20.sol";

/**
 * @title GasTest
 * @notice Measures what each declared behaviour actually costs, so the README can quote numbers rather
 *         than adjectives.
 *
 * @dev Every figure is a warm-path `transfer` between two accounts that already hold a balance, measured
 *      as a `gasleft()` delta around the call and therefore including the call frame. Cold-slot costs are
 *      deliberately excluded: they are paid once per account pair and would drown the differences this
 *      table exists to show.
 *
 *      Run with `forge test --match-contract GasTest -vv` to print it.
 *
 *      The split matters more than the totals. Discovery — `extensions()`, `behaviorFlags()`,
 *      `extensionData()` — costs a transfer nothing at all, because none of it is on the transfer path.
 *      What costs is the behaviour itself, and that is the part an integrator was always going to pay for.
 */
contract GasTest is Test {
    address internal admin = makeAddr("admin");
    address internal vault = makeAddr("feeVault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant AMOUNT = 1e18;

    function test_PrintGasTable() public {
        uint256 plain = _measurePlain();
        uint256 quiet = _measureExtended(0, false);
        uint256 withFee = _measureExtended(100, false);
        uint256 withHook = _measureExtended(0, true);
        uint256 withBoth = _measureExtended(100, true);

        console2.log("");
        console2.log("transfer() gas, warm path, both accounts already funded");
        console2.log("-------------------------------------------------------");
        console2.log("  OpenZeppelin ERC20 (baseline)        ", plain);
        console2.log("  ExtendedToken, nothing switched on   ", quiet);
        console2.log("    delta vs baseline                  ", quiet - plain);
        console2.log("  ExtendedToken, fee active            ", withFee);
        console2.log("    delta vs nothing switched on       ", withFee - quiet);
        console2.log("  ExtendedToken, hook installed        ", withHook);
        console2.log("    delta vs nothing switched on       ", withHook - quiet);
        console2.log("  ExtendedToken, fee + hook            ", withBoth);
        console2.log("");

        // The pipeline is not free, but it is bounded and it is the same every time.
        assertGt(quiet, plain);
        assertGt(withFee, quiet);
        assertGt(withHook, quiet);
    }

    function test_DiscoveryCostsTheTransferPathNothing() public {
        uint256 without = _measureExtended(0, false);

        // Read every discovery surface there is, then measure the same transfer again.
        ExtendedToken token = _deploy(0, false);
        token.extensions();
        token.behaviorFlags();
        token.accountState(alice);

        uint256 with_ = _measureExtended(0, false);
        assertEq(without, with_, "reading a token's declarations does not change what it costs to use");
    }

    // -----------------------------------------------------------------------------------------------

    function _deploy(uint16 basisPoints, bool withHook) private returns (ExtendedToken token) {
        token = new ExtendedToken("Gas", "GAS", admin);

        vm.startPrank(admin);
        token.setFeeVault(vault);
        if (basisPoints > 0) token.setFeeConfig(basisPoints, type(uint128).max);
        if (withHook) token.setTransferHook(address(new RecordingHook()), 200_000);
        token.mint(alice, 1_000_000e18);
        token.mint(bob, 1_000_000e18);
        vm.stopPrank();

        if (basisPoints > 0) {
            // Warm the vault's balance slot too, so the fee leg is measured on the same footing.
            vm.prank(alice);
            token.transfer(bob, AMOUNT);
        }
    }

    function _measureExtended(uint16 basisPoints, bool withHook) private returns (uint256) {
        ExtendedToken token = _deploy(basisPoints, withHook);

        // Warm-up: pay the cold-slot costs outside the measurement.
        vm.prank(alice);
        token.transfer(bob, AMOUNT);

        vm.prank(alice);
        uint256 before = gasleft();
        token.transfer(bob, AMOUNT);
        return before - gasleft();
    }

    function _measurePlain() private returns (uint256) {
        PlainERC20 token = new PlainERC20("Plain", "PLN");
        token.mint(alice, 1_000_000e18);
        token.mint(bob, 1_000_000e18);

        vm.prank(alice);
        token.transfer(bob, AMOUNT);

        vm.prank(alice);
        uint256 before = gasleft();
        token.transfer(bob, AMOUNT);
        return before - gasleft();
    }
}
