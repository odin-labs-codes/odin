// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20TransferFee} from "../interfaces/IERC20TransferFee.sol";
import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC20ExtensionCore} from "./ERC20ExtensionCore.sol";

/**
 * @title ERC20TransferFee
 * @notice A transfer fee that is pre-computable, hard-capped, and invertible.
 *
 * @dev The fee itself is the easy part. What makes fee-on-transfer tokens unintegratable is that a caller
 *      cannot answer "how much will actually arrive?" without trying it, so every protocol either wraps the
 *      call in balance snapshots or refuses the token. This module answers the question directly.
 *
 *      ## Rounding and direction
 *
 *      `fee = min(floor(amount * basisPoints / 10_000), maximumFee)`, withheld from the amount. Flooring
 *      rounds in the sender's favour, and the sender is the party who did not choose to pay a fee.
 *
 *      ## Why `transferExactOut` exists
 *
 *      A caller who needs a recipient to end up with exactly N has to invert the fee function. Inverting a
 *      floored ratio by hand goes wrong at the boundaries — `N * 10_000 / (10_000 - bps)` is off by one for
 *      most N — and every caller that gets it wrong either overpays or reverts. {_amountInForExactOut}
 *      solves it once, exactly.
 *
 *      ## The ceiling that cannot move
 *
 *      {MAX_FEE_BASIS_POINTS} is a compile-time constant, so `fee <= amount * MAX_FEE_BASIS_POINTS / 10_000`
 *      holds for the lifetime of the deployment no matter what the authority does. A fee with no ceiling at
 *      all is indistinguishable from theft on a delay.
 */
abstract contract ERC20TransferFee is ERC20ExtensionCore, IERC20TransferFee {
    /// @notice Basis-point denominator. 10_000 basis points is 100%.
    uint256 public constant FEE_BASIS_POINT_DENOMINATOR = 10_000;

    /**
     * @notice The highest fee rate this token will ever accept, as a compile-time constant.
     * @dev 10%. Also keeps `FEE_BASIS_POINT_DENOMINATOR - basisPoints` strictly positive, without which
     *      {transferExactOut} has no solution.
     */
    uint16 public constant MAX_FEE_BASIS_POINTS = 1_000;

    uint16 private _basisPoints;
    address private _feeVault;
    uint256 private _maximumFee;
    mapping(address account => bool exempt) private _feeExempt;

    function __ERC20TransferFee_init() internal onlyInitializing {
        _registerExtension(ExtensionIds.TRANSFER_FEE, BehaviorFlags.FEE_ON_TRANSFER);
    }

    // -----------------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20TransferFee
    function computeFee(address from, address to, uint256 amount) public view virtual returns (uint256) {
        if (from == address(0) || to == address(0)) return 0;
        if (isFeeExempt(from) || isFeeExempt(to)) return 0;

        uint16 basisPoints = _basisPoints;
        if (basisPoints == 0) return 0;

        return Math.min(Math.mulDiv(amount, basisPoints, FEE_BASIS_POINT_DENOMINATOR), _maximumFee);
    }

    /// @inheritdoc IERC20TransferFee
    function isFeeExempt(address account) public view virtual returns (bool) {
        // The vault is exempt by construction: charging a fee on the vault's own withdrawals would make the
        // fee recursive and would let it accumulate balance it can never fully move.
        return _feeExempt[account] || (account != address(0) && account == _feeVault);
    }

    /// @inheritdoc IERC20TransferFee
    function maximumFee() public view virtual returns (uint256) {
        // Zero while the rate is zero. Clamping further — to the largest fee the rate could actually
        // produce — was considered and rejected: the only caps it would lower are ones near
        // `type(uint256).max`, so it would cost a `mulDiv` on every call to replace one astronomical
        // number with another, while leaving the bound just as loose for the caps that occur in practice.
        return _basisPoints == 0 ? 0 : _maximumFee;
    }

    /// @inheritdoc IERC20TransferFee
    function feeVault() public view virtual override returns (address) {
        return _feeVault;
    }

    /// @inheritdoc IERC20TransferFee
    function feeBasisPoints() public view virtual override returns (uint16) {
        return _basisPoints;
    }

    /// @inheritdoc IERC20TransferFee
    function computeAmountInForExactOut(address from, address to, uint256 amountOut)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _amountInForExactOut(from, to, amountOut);
    }

    /// @inheritdoc ERC20ExtensionCore
    function _extensionData(bytes4 extensionId) internal view virtual override returns (bytes memory) {
        if (extensionId == ExtensionIds.TRANSFER_FEE) {
            return abi.encode(_basisPoints, _maximumFee, _feeVault);
        }
        return super._extensionData(extensionId);
    }

    // -----------------------------------------------------------------------------------------------
    // Exact-output transfers
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20TransferFee
    function transferExactOut(address to, uint256 amountOut) public virtual returns (uint256 amountIn) {
        address owner = _msgSender();
        amountIn = _amountInForExactOut(owner, to, amountOut);
        _transfer(owner, to, amountIn);
    }

    /// @inheritdoc IERC20TransferFee
    function transferFromExactOut(address from, address to, uint256 amountOut)
        public
        virtual
        returns (uint256 amountIn)
    {
        amountIn = _amountInForExactOut(from, to, amountOut);
        // The allowance covers the gross amount, because the gross amount is what leaves `from`.
        _spendAllowance(from, _msgSender(), amountIn);
        _transfer(from, to, amountIn);
    }

    /**
     * @dev Smallest `amountIn` with `amountIn - computeFee(from, to, amountIn) == amountOut`.
     *
     *      Write `b` for the rate, `D` for the denominator and `k = D - b`. The net received is
     *      `net(x) = x - floor(x*b/D) = ceil(x*k/D)`, so `net(x) == amountOut` holds exactly for
     *      `(amountOut-1)*D/k < x <= amountOut*D/k`, and the smallest such integer is
     *      `floor((amountOut-1)*D/k) + 1`.
     *
     *      Rounding `amountOut*D/k` up instead — the obvious first attempt — lands on the largest input that
     *      delivers `amountOut` for some inputs, and on one that overdelivers for the rest.
     *
     *      `Math.mulDiv` carries the intermediate product in 512 bits, so the only inputs that revert are
     *      ones whose answer genuinely does not fit in a `uint256`.
     */
    function _amountInForExactOut(address from, address to, uint256 amountOut)
        internal
        view
        virtual
        returns (uint256)
    {
        if (amountOut == 0) return 0;
        if (isFeeExempt(from) || isFeeExempt(to)) return amountOut;

        uint16 basisPoints = _basisPoints;
        if (basisPoints == 0) return amountOut;

        uint256 k = FEE_BASIS_POINT_DENOMINATOR - basisPoints; // > 0: basisPoints <= MAX_FEE_BASIS_POINTS
        return Math.mulDiv(amountOut - 1, FEE_BASIS_POINT_DENOMINATOR, k) + 1;
    }

    // -----------------------------------------------------------------------------------------------
    // Transfer pipeline — phase 2
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc ERC20ExtensionCore
    function _collectTransferFee(address from, address to, uint256 value)
        internal
        virtual
        override
        returns (uint256)
    {
        uint256 fee = computeFee(from, to, value);
        if (fee > 0) {
            // Its own leg, its own `Transfer` event: an indexer that only saw the net leg would report
            // supply vanishing.
            _rawUpdate(from, _feeVault, fee);
            emit TransferFeeCollected(from, to, fee);
        }
        return super._collectTransferFee(from, to, value) + fee;
    }

    // -----------------------------------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------------------------------

    /// @notice Sets the fee rate and the absolute per-transfer cap.
    function setFeeConfig(uint16 basisPoints, uint256 newMaximumFee) external virtual {
        _authorizeExtensionConfig(ExtensionIds.TRANSFER_FEE);
        if (basisPoints > MAX_FEE_BASIS_POINTS) {
            revert ERC20FeeBasisPointsTooHigh(basisPoints, MAX_FEE_BASIS_POINTS);
        }

        // A non-zero rate with no vault would send fees to address(0), which burns them and makes total
        // supply drift downwards on every transfer — a rebase nobody declared.
        if (basisPoints > 0 && _feeVault == address(0)) revert ERC20FeeVaultNotSet();

        _basisPoints = basisPoints;
        _maximumFee = newMaximumFee;

        emit FeeConfigUpdated(basisPoints, newMaximumFee);
        _emitExtensionConfigured(ExtensionIds.TRANSFER_FEE);
    }

    /// @notice Sets the address that collects fees. Cannot be the zero address.
    function setFeeVault(address newFeeVault) external virtual {
        _authorizeExtensionConfig(ExtensionIds.TRANSFER_FEE);
        if (newFeeVault == address(0)) revert ERC20InvalidFeeVault(newFeeVault);

        _feeVault = newFeeVault;

        emit FeeVaultUpdated(newFeeVault);
        _emitExtensionConfigured(ExtensionIds.TRANSFER_FEE);
    }

    /// @notice Exempts an account from the fee, or revokes the exemption. Typically used for AMM pools.
    function setFeeExempt(address account, bool exempt) external virtual {
        _authorizeExtensionConfig(ExtensionIds.TRANSFER_FEE);

        _feeExempt[account] = exempt;

        emit FeeExemptionUpdated(account, exempt);
    }
}
