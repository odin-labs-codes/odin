// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Behavior} from "../src/interfaces/IERC20Behavior.sol";
import {IERC20CheckedTransfer} from "../src/interfaces/IERC20CheckedTransfer.sol";
import {IERC20Extensions} from "../src/interfaces/IERC20Extensions.sol";
import {IERC20TransferFee} from "../src/interfaces/IERC20TransferFee.sol";
import {IERC20TransferRestriction} from "../src/interfaces/IERC20TransferRestriction.sol";
import {BERCVerification} from "../src/libraries/BERCVerification.sol";
import {BehaviorFlags} from "../src/libraries/BehaviorFlags.sol";
import {BaseTest} from "./BaseTest.sol";

/**
 * @title IntegrationClient
 * @notice Everything `docs/INTEGRATION.md` tells an external protocol to do, written the way it tells them
 *         to write it: against the interfaces and the libraries, with no import from `src/extensions`.
 *
 * @dev This contract exists to fail compilation. A function the documentation uses but the interface never
 *      declared is invisible to every test that reaches through the concrete type — and three of them
 *      (`computeAmountInForExactOut`, `feeBasisPoints`, `feeVault`) were missing exactly that way, so the
 *      published example did not build for anyone who copied it.
 */
contract IntegrationClient {
    /// @dev The five-minute path: read the declaration, branch on it.
    function willArrive(address token, address from, address to, uint256 amount) external view returns (uint256) {
        uint256 flags = IERC20Behavior(token).behaviorFlags();
        if (flags & BehaviorFlags.FEE_ON_TRANSFER == 0) return amount;
        return amount - IERC20TransferFee(token).computeFee(from, to, amount);
    }

    /// @dev The quote that outlives a configuration change, built on the immutable ceiling.
    function worstCaseArrival(address token, uint256 amount) external view returns (uint256) {
        uint256 ceiling = IERC20TransferFee(token).MAX_FEE_BASIS_POINTS();
        uint256 worstFee = (amount * ceiling) / 10_000;
        return amount > worstFee ? amount - worstFee : 0;
    }

    /// @dev The exact-output direction, including the inverse quote the docs recommend.
    function costOfDelivering(address token, address from, address to, uint256 amountOut)
        external
        view
        returns (uint256)
    {
        return IERC20TransferFee(token).computeAmountInForExactOut(from, to, amountOut);
    }

    function currentFeeConfiguration(address token)
        external
        view
        returns (uint16 basisPoints, uint256 cap, address vault, bool poolExempt)
    {
        basisPoints = IERC20TransferFee(token).feeBasisPoints();
        cap = IERC20TransferFee(token).maximumFee();
        vault = IERC20TransferFee(token).feeVault();
        poolExempt = IERC20TransferFee(token).isFeeExempt(address(this));
    }

    /// @dev The router path: state a floor, let the token enforce it.
    function pullChecked(address token, address from, uint256 amount, uint256 minReceived)
        external
        returns (uint256)
    {
        return IERC20CheckedTransfer(token).transferFromChecked(from, address(this), amount, minReceived, 0);
    }

    /// @dev The exact-output path, with the ceiling on what it may cost.
    function pullExactOut(address token, address from, uint256 amountOut, uint256 maxAmountIn)
        external
        returns (uint256)
    {
        return IERC20TransferFee(token).transferFromExactOutChecked(from, address(this), amountOut, maxAmountIn, 0);
    }

    /// @dev Discovery and screening.
    function screen(address token, address from, address to, uint256 amount) external view returns (uint8) {
        if (IERC20Behavior(token).behaviorFlags() & (BehaviorFlags.PAUSABLE | BehaviorFlags.BLOCKLIST) == 0) {
            return 0;
        }
        return IERC20TransferRestriction(token).detectTransferRestriction(from, to, amount);
    }

    function installedExtensions(address token) external view returns (bytes4[] memory) {
        return IERC20Extensions(token).extensions();
    }

    function epoch(address token) external view returns (uint64) {
        return IERC20CheckedTransfer(token).configurationEpoch();
    }

    function isVerified(address token, address runtime) external view returns (bool) {
        return BERCVerification.isClonedFrom(token, runtime);
    }
}

contract IntegrationClientTest is BaseTest {
    IntegrationClient internal client;

    function setUp() public override {
        super.setUp();
        client = new IntegrationClient();
        _setFee(250, 1000e18);

        vm.prank(alice);
        token.approve(address(client), type(uint256).max);
    }

    function test_TheDocumentedReadsAllResolve() public view {
        assertEq(client.willArrive(address(token), alice, carol, 1000e18), 1000e18 - 25e18);
        assertGt(client.worstCaseArrival(address(token), 1000e18), 0);
        assertGt(client.costOfDelivering(address(token), alice, carol, 1000e18), 1000e18);

        (uint16 basisPoints, uint256 cap, address vault_, bool poolExempt) =
            client.currentFeeConfiguration(address(token));
        assertEq(basisPoints, 250);
        assertEq(cap, 1000e18);
        assertEq(vault_, vault);
        assertFalse(poolExempt);

        assertEq(client.screen(address(token), alice, carol, 1e18), 0);
        assertEq(client.installedExtensions(address(token)).length, 4);
        assertGt(client.epoch(address(token)), 0);
    }

    function test_TheDocumentedTransfersAllExecute() public {
        uint256 quoted = client.willArrive(address(token), alice, address(client), 1000e18);

        uint256 received = client.pullChecked(address(token), alice, 1000e18, quoted);
        assertEq(received, quoted, "the checked pull delivers what the quote promised");

        uint256 ceiling = client.costOfDelivering(address(token), alice, address(client), 500e18);
        uint256 paid = client.pullExactOut(address(token), alice, 500e18, ceiling);
        assertEq(paid, ceiling, "the exact-output pull costs what the inverse quote said");
    }

    /// @dev A self-declared token is not a clone of anything, which the client must be able to establish.
    function test_TheVerificationHelperResolves() public view {
        assertFalse(client.isVerified(address(token), address(token)));
    }
}
