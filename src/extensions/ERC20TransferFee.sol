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
 *      call in balance snapshots or refuses the token. This module answers the question directly, and the
 *      test suite pins the answer: for any amount, `computeFee` equals the difference between what leaves
 *      the sender and what reaches the recipient, in the same transaction.
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
 *      solves it once, exactly, including where the absolute cap takes over from the rate.
 *
 *      ## The ceiling that cannot move
 *
 *      {maximumFee} is authority-mutable, which means an integrator caching it must also watch
 *      `FeeConfigUpdated`. {MAX_FEE_BASIS_POINTS} is not: it is a compile-time constant, so
 *      `fee <= amount * MAX_FEE_BASIS_POINTS / 10_000` holds for the lifetime of the deployment no matter
 *      what the authority does. A fee with no ceiling at all is indistinguishable from theft on a delay.
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

    /// @custom:storage-location erc7201:berc.storage.TransferFee
    struct TransferFeeStorage {
        uint16 basisPoints;
        address feeVault;
        uint256 maximumFee;
        mapping(address account => bool exempt) feeExempt;
    }

    // keccak256(abi.encode(uint256(keccak256("berc.storage.TransferFee")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TRANSFER_FEE_STORAGE =
        0xdd69031206c835003421b46d33beabb676aa67ba324dd4f2c722dae5d7ba4800;

    function _getTransferFeeStorage() private pure returns (TransferFeeStorage storage $) {
        assembly ("memory-safe") {
            $.slot := TRANSFER_FEE_STORAGE
        }
    }

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

        TransferFeeStorage storage $ = _getTransferFeeStorage();
        uint16 basisPoints = $.basisPoints;
        if (basisPoints == 0) return 0;

        return Math.min(Math.mulDiv(amount, basisPoints, FEE_BASIS_POINT_DENOMINATOR), $.maximumFee);
    }

    /// @inheritdoc IERC20TransferFee
    function maximumFee() public view virtual returns (uint256) {
        TransferFeeStorage storage $ = _getTransferFeeStorage();
        // Zero while the rate is zero. Clamping further — to the largest fee the rate could actually
        // produce — was considered and rejected: the only caps it would lower are ones near
        // `type(uint256).max`, so it would cost a `mulDiv` on every call to replace one astronomical
        // number with another, while leaving the bound just as loose for the caps that occur in practice.
        return $.basisPoints == 0 ? 0 : $.maximumFee;
    }

    /// @inheritdoc IERC20TransferFee
    function isFeeExempt(address account) public view virtual returns (bool) {
        TransferFeeStorage storage $ = _getTransferFeeStorage();
        // The vault is exempt by construction: charging a fee on the vault's own withdrawals would make the
        // fee recursive and would let it accumulate balance it can never fully move.
        return $.feeExempt[account] || (account != address(0) && account == $.feeVault);
    }

    /// @inheritdoc IERC20TransferFee
    function feeVault() public view virtual override returns (address) {
        return _getTransferFeeStorage().feeVault;
    }

    /// @inheritdoc IERC20TransferFee
    function feeBasisPoints() public view virtual override returns (uint16) {
        return _getTransferFeeStorage().basisPoints;
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
            TransferFeeStorage storage $ = _getTransferFeeStorage();
            return abi.encode($.basisPoints, $.maximumFee, $.feeVault);
        }
        return super._extensionData(extensionId);
    }

    /// @inheritdoc ERC20ExtensionCore
    function _accountFeeExempt(address account) internal view virtual override returns (bool) {
        return isFeeExempt(account);
    }

    // -----------------------------------------------------------------------------------------------
    // Exact-output transfers
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20TransferFee
    function transferExactOut(address to, uint256 amountOut) public virtual returns (uint256 amountIn) {
        return transferExactOutChecked(to, amountOut, type(uint256).max, 0);
    }

    /// @inheritdoc IERC20TransferFee
    function transferFromExactOut(address from, address to, uint256 amountOut)
        public
        virtual
        returns (uint256 amountIn)
    {
        return transferFromExactOutChecked(from, to, amountOut, type(uint256).max, 0);
    }

    /// @inheritdoc IERC20TransferFee
    function transferExactOutChecked(
        address to,
        uint256 amountOut,
        uint256 maxAmountIn,
        uint64 expectedConfigurationEpoch
    ) public virtual returns (uint256 amountIn) {
        _requireConfigurationEpoch(expectedConfigurationEpoch);

        address owner = _msgSender();
        amountIn = _amountInForExactOut(owner, to, amountOut);
        if (amountIn > maxAmountIn) revert ERC20ExactOutInputTooHigh(amountIn, maxAmountIn);

        _transfer(owner, to, amountIn);
    }

    /// @inheritdoc IERC20TransferFee
    function transferFromExactOutChecked(
        address from,
        address to,
        uint256 amountOut,
        uint256 maxAmountIn,
        uint64 expectedConfigurationEpoch
    ) public virtual returns (uint256 amountIn) {
        _requireConfigurationEpoch(expectedConfigurationEpoch);

        amountIn = _amountInForExactOut(from, to, amountOut);
        if (amountIn > maxAmountIn) revert ERC20ExactOutInputTooHigh(amountIn, maxAmountIn);

        // The allowance covers the gross amount, because the gross amount is what leaves `from`.
        _spendAllowance(from, _msgSender(), amountIn);
        _transfer(from, to, amountIn);
    }

    /**
     * @dev Smallest `amountIn` with `amountIn - computeFee(from, to, amountIn) == amountOut`.
     *
     *      Write `b` for the rate, `D` for the denominator and `k = D - b`. Where the cap does not bind,
     *      the net received is `net(x) = x - floor(x*b/D) = ceil(x*k/D)`, so `net(x) == amountOut` holds
     *      exactly for `(amountOut-1)*D/k < x <= amountOut*D/k`, and the smallest such integer is
     *      `floor((amountOut-1)*D/k) + 1`.
     *
     *      Where the cap does bind, `net(x) = x - maximumFee`, so the answer is `amountOut + maximumFee`.
     *      Which branch applies is decided by evaluating the fee at the uncapped candidate: because `net`
     *      never gains more than 1 per step, the two branches cannot both miss, and they agree on the
     *      boundary where the uncapped fee equals the cap exactly.
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
        // The address-level rejections the matching transfer would make, in the same order, so a caller
        // simulating against this view is not told an impossible transfer will work. It is not a dry run:
        // a pause, a freeze, a hook or an insufficient balance can still stop the transfer afterwards, and
        // none of them are visible from here. A sender who is also the recipient loses the fee and gains
        // nothing, which no return value describes honestly.
        if (from == to) revert ERC20ExactOutToSelf(from);
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));

        if (amountOut == 0) return 0;
        if (isFeeExempt(from) || isFeeExempt(to)) return amountOut;

        TransferFeeStorage storage $ = _getTransferFeeStorage();
        uint16 basisPoints = $.basisPoints;
        if (basisPoints == 0) return amountOut;

        uint256 cap = $.maximumFee;
        uint256 k = FEE_BASIS_POINT_DENOMINATOR - basisPoints; // > 0: basisPoints <= MAX_FEE_BASIS_POINTS

        // `mulDiv` reverts when the *uncapped* inverse overflows, which says nothing about whether the real
        // answer fits: with a cap of zero the fee is always zero and the answer is `amountOut` itself, yet
        // the uncapped candidate for `amountOut = type(uint256).max` is about 1.11x that. So the candidate
        // is computed only where it exists, and its absence is treated as evidence that the cap binds.
        //
        // The order matters and cannot be inverted. Testing the capped candidate first and returning it as
        // soon as its fee reaches the cap loses minimality: with a 10% rate and a cap of 5, both 49 and 50
        // deliver exactly 45, and `amountOut + cap` is the larger of the two.
        //
        // The limit rounds **up**, and the comparison is strict. Rounding down excluded `floor(MAX*k/D)`,
        // which is a perfectly representable input — with a 10% rate and no effective cap, an `amountOut`
        // one above it inverts to exactly `type(uint256).max` and was being sent down the capped path to
        // overflow instead. Rounding up admits it, and cannot admit anything whose `+ 1` overflows: an `a`
        // below `ceil(MAX*k/D)` has `a*D/k < MAX`, so the `mulDiv` lands at `MAX - 1` at the highest.
        uint256 uncappedLimit = Math.mulDiv(type(uint256).max, k, FEE_BASIS_POINT_DENOMINATOR, Math.Rounding.Ceil);
        if (amountOut - 1 < uncappedLimit) {
            uint256 uncapped = Math.mulDiv(amountOut - 1, FEE_BASIS_POINT_DENOMINATOR, k) + 1;
            if (Math.mulDiv(uncapped, basisPoints, FEE_BASIS_POINT_DENOMINATOR) <= cap) return uncapped;
        }

        // Checked before the addition so the caller gets the declared error rather than a bare panic.
        if (cap > type(uint256).max - amountOut) revert ERC20ExactOutUnrepresentable(amountOut);
        uint256 capped = amountOut + cap;

        // Belt and braces, and provably so. Reaching here without the cap binding would mean the answer was
        // the uncapped candidate after all, which cannot happen: writing `b` for the rate, `k = D - b` and
        // `M` for `type(uint256).max`, arriving here needs `amountOut > M*k/D`, surviving the addition needs
        // `cap < M*b/D`, and a non-binding cap needs `cap > amountOut*b/k`. The first and third give
        // `cap > M*b/D`, which contradicts the second. The check stays because that argument depends on the
        // exact comparison above it, and an edit there should fail loudly rather than return a wrong number.
        if (Math.mulDiv(capped, basisPoints, FEE_BASIS_POINT_DENOMINATOR) < cap) {
            revert ERC20ExactOutUnrepresentable(amountOut);
        }
        return capped;
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
            _rawUpdate(from, _getTransferFeeStorage().feeVault, fee);
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

        TransferFeeStorage storage $ = _getTransferFeeStorage();
        // A non-zero rate with no vault would send fees to address(0), which burns them and makes total
        // supply drift downwards on every transfer — a rebase nobody declared.
        if (basisPoints > 0 && $.feeVault == address(0)) revert ERC20FeeVaultNotSet();

        $.basisPoints = basisPoints;
        $.maximumFee = newMaximumFee;

        emit FeeConfigUpdated(basisPoints, newMaximumFee);
        _emitExtensionConfigured(ExtensionIds.TRANSFER_FEE);
        _advanceConfigurationEpoch();
    }

    /// @notice Sets the address that collects fees. Cannot be the zero address.
    function setFeeVault(address newFeeVault) external virtual {
        _authorizeExtensionConfig(ExtensionIds.TRANSFER_FEE);
        if (newFeeVault == address(0)) revert ERC20InvalidFeeVault(newFeeVault);

        TransferFeeStorage storage $ = _getTransferFeeStorage();
        address previousVault = $.feeVault;
        $.feeVault = newFeeVault;

        // The vault's exemption is implied by being the vault, so rotating it silently changes the
        // effective `feeExempt` of two accounts that were never named in a `setFeeExempt` call. Both are
        // touched so `accountState().configuredAt` still answers "when did this account's treatment last
        // change" rather than pointing at a change that never mentioned them.
        if (previousVault != address(0)) _touchAccountState(previousVault);
        _touchAccountState(newFeeVault);

        emit FeeVaultUpdated(newFeeVault);
        _emitExtensionConfigured(ExtensionIds.TRANSFER_FEE);
        _advanceConfigurationEpoch();
    }

    /// @notice Exempts an account from the fee, or revokes the exemption. Typically used for AMM pools.
    function setFeeExempt(address account, bool exempt) external virtual {
        _authorizeExtensionConfig(ExtensionIds.TRANSFER_FEE);

        _getTransferFeeStorage().feeExempt[account] = exempt;
        _touchAccountState(account);

        emit FeeExemptionUpdated(account, exempt);
        // Per-account, but it changes what a transfer costs just as directly as the rate does.
        _advanceConfigurationEpoch();
    }
}
