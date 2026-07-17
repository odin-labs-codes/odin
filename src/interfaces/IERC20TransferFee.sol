// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC20TransferFee
 * @notice A transfer fee that an integrator can predict and bound.
 *
 * @dev Fee-on-transfer tokens are refused by most protocols, and the reason is not the fee. It is that the
 *      protocol cannot find out what the fee will be without performing the transfer. {computeFee} returns,
 *      in a `view` call, exactly what a transfer with those arguments would withhold in the same transaction,
 *      and {maximumFee} bounds it over every possible amount so a caller can size worst-case slippage
 *      without iterating.
 *
 *      **Fee direction.** The fee is withheld *from* the transferred amount, never added on top of it.
 *      `transfer(to, amount)` always debits the sender exactly `amount` — that is ERC-20's meaning and this
 *      extension does not touch it — and credits the recipient `amount - computeFee(sender, to, amount)`.
 *
 *      Mint and burn are never charged: a fee on minting is an accounting error, and a fee on burning is a
 *      transfer to the vault dressed up as a supply reduction.
 */
interface IERC20TransferFee {
    /// @notice A fee rate above the immutable ceiling was requested.
    error ERC20FeeBasisPointsTooHigh(uint16 basisPoints, uint16 maxBasisPoints);

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

    /**
     * @notice The fee a transfer with these arguments would withhold, right now.
     * @dev Exact, not an estimate: within one transaction, `transfer` withholds precisely this much.
     *      Returns zero when `from` or `to` is the zero address.
     * @return fee The amount withheld from `amount`; the recipient receives `amount - fee`.
     */
    function computeFee(address from, address to, uint256 amount) external view returns (uint256 fee);

    /// @notice The current fee rate in basis points, against a denominator of 10,000.
    function feeBasisPoints() external view returns (uint16);

    /// @notice The address collecting fees, or the zero address if none is configured.
    function feeVault() external view returns (address);

    /**
     * @notice An upper bound on the fee any single transfer can incur under the current configuration.
     *
     * @dev Note that this is the *current* cap, and the authority can raise it. A quote that has to
     *      survive a configuration change must be built on {MAX_FEE_BASIS_POINTS} instead.
     *
     *      Returns zero while the rate is zero, which is the one case where reporting the stored cap
     *      would be actively misleading rather than merely loose.
     */
    function maximumFee() external view returns (uint256);

    /**
     * @notice The highest rate this deployment will ever accept, as a compile-time constant.
     * @dev The one fee figure no authority can move, which makes it the only sound basis for a quote that
     *      has to outlive a configuration change. `fee <= amount * MAX_FEE_BASIS_POINTS / 10_000` holds for
     *      the lifetime of the deployment. Cache it once.
     */
    function MAX_FEE_BASIS_POINTS() external view returns (uint16);
}
