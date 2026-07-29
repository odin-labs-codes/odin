// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC20TransferFee
 * @notice A transfer fee that an integrator can predict, bound, and route around.
 *
 * @dev Fee-on-transfer tokens are refused by most protocols, and the reason is not the fee. It is that the
 *      protocol cannot find out what the fee will be without performing the transfer. This interface removes
 *      that problem with three guarantees, none of which is useful without the other two:
 *
 *      - **Predictable.** {computeFee} returns, in a `view` call, exactly what a transfer with those
 *        arguments would withhold in the same transaction.
 *      - **Bounded.** {maximumFee} is an upper bound on {computeFee} over every possible amount under the
 *        current configuration, so a caller can size worst-case slippage without iterating. For a bound
 *        that also survives the authority changing that configuration, use {MAX_FEE_BASIS_POINTS}.
 *      - **Invertible.** {transferExactOut} lets a caller specify what the recipient must receive and pay
 *        whatever that costs, instead of solving for the input themselves and rounding it wrong.
 *
 *      **Fee direction.** The fee is withheld *from* the transferred amount, never added on top of it.
 *      `transfer(to, amount)` always debits the sender exactly `amount` — that is ERC-20's meaning and this
 *      extension does not touch it — and credits the recipient `amount - computeFee(sender, to, amount)`.
 *
 *      Mint and burn are never charged: a fee on minting is an accounting error, and a fee on burning is a
 *      transfer to the vault dressed up as a supply reduction.
 *
 *      Extension data encoding for {IERC20Extensions-extensionData}:
 *      `abi.encode(uint16 basisPoints, uint256 maximumFee, address feeVault)`.
 */
interface IERC20TransferFee {
    /// @notice A fee rate above the immutable ceiling was requested.
    error ERC20FeeBasisPointsTooHigh(uint16 basisPoints, uint16 maxBasisPoints);

    /// @notice Delivering `amountOut` would cost more than the caller was willing to spend.
    error ERC20ExactOutInputTooHigh(uint256 amountIn, uint256 maxAmountIn);

    /// @notice No input produces this output: the answer does not fit in a `uint256`.
    error ERC20ExactOutUnrepresentable(uint256 amountOut);

    /**
     * @notice An exact-output transfer named the sender as the recipient.
     * @dev Rejected rather than accommodated. The whole promise of this family is that `to` ends up
     *      `amountOut` better off; when `to` is also paying, its balance falls by the fee and rises by
     *      nothing, so there is no honest value to return and no version of the guarantee that holds.
     */
    error ERC20ExactOutToSelf(address account);

    /// @notice A non-zero fee rate was requested while no vault is set to receive the fees.
    error ERC20FeeVaultNotSet();

    /// @notice The fee vault cannot be the zero address; that would burn fees and shrink total supply.
    error ERC20InvalidFeeVault(address vault);

    /// @notice Emitted for every transfer that actually withheld a fee.
    event TransferFeeCollected(address indexed from, address indexed to, uint256 fee);

    /// @notice Emitted when the fee rate or the absolute cap changes.
    event FeeConfigUpdated(uint16 basisPoints, uint256 maximumFee);

    /// @notice Emitted when the address collecting fees changes.
    event FeeVaultUpdated(address indexed vault);

    /// @notice Emitted when an account's fee exemption is granted or revoked.
    event FeeExemptionUpdated(address indexed account, bool exempt);

    /**
     * @notice The fee a transfer with these arguments would withhold, right now.
     * @dev Exact, not an estimate: within one transaction, `transfer` withholds precisely this much.
     *      Returns zero when `from` or `to` is the zero address, and when either side is fee-exempt.
     * @return fee The amount withheld from `amount`; the recipient receives `amount - fee`.
     */
    function computeFee(address from, address to, uint256 amount) external view returns (uint256 fee);

    /**
     * @notice The smallest input that makes `to` receive exactly `amountOut`, without transferring.
     *
     * @dev Agreement with the matching transfer covers **address validity and fee arithmetic only**: a
     *      zero sender or recipient, a sender who is also the recipient, and an answer that does not fit
     *      in a `uint256`. It is not a dry run. The transfer can still fail afterwards for reasons this
     *      view never looks at — a pause, a frozen account, non-transferability, a hook that rejects or
     *      runs out of gas, or simply an insufficient balance or allowance. Screen those separately with
     *      {IERC20TransferRestriction-detectTransferRestriction} and the usual balance checks.
     */
    function computeAmountInForExactOut(address from, address to, uint256 amountOut)
        external
        view
        returns (uint256 amountIn);

    /// @notice The current fee rate in basis points, against a denominator of 10,000.
    function feeBasisPoints() external view returns (uint16);

    /**
     * @notice The highest rate this deployment will ever accept, as a compile-time constant.
     * @dev The one fee figure no authority can move, which makes it the only sound basis for a quote that
     *      has to outlive a configuration change. `fee <= amount * MAX_FEE_BASIS_POINTS / 10_000` holds for
     *      the lifetime of the deployment. Cache it once.
     */
    function MAX_FEE_BASIS_POINTS() external view returns (uint16);

    /// @notice The address collecting fees, or the zero address if none is configured.
    function feeVault() external view returns (address);

    /**
     * @notice Transfer so that `to` receives exactly `amountOut`, whatever the fee costs.
     * @dev The recipient's balance increases by exactly `amountOut` with no rounding slack. The sender is
     *      debited the returned `amountIn`, which is the smallest input that produces that output.
     * @return amountIn The total debited from the caller, fee included.
     */
    function transferExactOut(address to, uint256 amountOut) external returns (uint256 amountIn);

    /**
     * @notice {transferExactOut} on behalf of `from`, spending the caller's allowance.
     * @dev The allowance is spent on the gross `amountIn`, since that is what leaves `from`.
     */
    function transferFromExactOut(address from, address to, uint256 amountOut) external returns (uint256 amountIn);

    /**
     * @notice {transferExactOut} with a ceiling on what the caller will pay for it.
     *
     * @dev Exact-output has the opposite exposure to exact-input, and needs the opposite guard. Fixing the
     *      output means the *input* floats: raise the rate between the caller reading `computeFee` and
     *      their transaction landing, and the recipient still gets `amountOut` while the sender quietly
     *      pays more. `minAmountReceived` cannot express that — the received amount is exactly what was
     *      asked for — so the ceiling has to be named on the other side.
     *
     * @param maxAmountIn The most the caller will part with, fee included. Pass `type(uint256).max` to
     *        accept any cost, which is what the unguarded {transferExactOut} does.
     * @param expectedConfigurationEpoch Pass `0` to skip the check, or the epoch the caller read. Same
     *        semantics and same caveats as {IERC20CheckedTransfer-transferChecked}.
     */
    function transferExactOutChecked(
        address to,
        uint256 amountOut,
        uint256 maxAmountIn,
        uint64 expectedConfigurationEpoch
    ) external returns (uint256 amountIn);

    /// @notice {transferExactOutChecked} on behalf of `from`, spending the caller's allowance.
    function transferFromExactOutChecked(
        address from,
        address to,
        uint256 amountOut,
        uint256 maxAmountIn,
        uint64 expectedConfigurationEpoch
    ) external returns (uint256 amountIn);

    /**
     * @notice An upper bound on the fee any single transfer can incur under the current configuration.
     *
     * @dev Never exceeded, and reached by any amount at or above
     *      `Math.mulDiv(maximumFee(), 10_000, feeBasisPoints(), Math.Rounding.Ceil)` — rounded **up**, and
     *      computed with `mulDiv` so the intermediate product cannot overflow. So it is the tightest useful
     *      figure for every configuration whose cap is within reach of its rate, which is every
     *      configuration meant to bind.
     *
     *      It is *not* reached when the cap is set beyond what the rate can produce: a cap above roughly
     *      `type(uint256).max / 10` is unreachable outright, and in practice any cap above
     *      `totalSupply * feeBasisPoints() / 10_000` is unreachable too, because no transfer that large can
     *      exist. A caller sizing worst-case slippage is safe either way; a caller wanting the smallest
     *      truthful figure should min this against what the rate can produce on the amounts they move.
     *
     *      Note also that this is the *current* cap, and the authority can raise it. A quote that has to
     *      survive a configuration change must be built on {MAX_FEE_BASIS_POINTS} instead.
     *
     *      Returns zero while the rate is zero, which is the one case where reporting the stored cap would
     *      be actively misleading rather than merely loose.
     *
     *      The rate and the cap are both authority-mutable, and both emit {FeeConfigUpdated}. Independently
     *      of either, the fee on a transfer of `amount` never exceeds
     *      `amount * MAX_FEE_BASIS_POINTS / 10_000`, and that ceiling is a compile-time constant.
     */
    function maximumFee() external view returns (uint256);

    /// @notice Whether transfers touching this account are exempt from the fee. The vault is always exempt.
    function isFeeExempt(address account) external view returns (bool);
}
