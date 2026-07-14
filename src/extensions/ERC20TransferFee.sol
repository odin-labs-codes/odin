// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20TransferFee} from "../interfaces/IERC20TransferFee.sol";
import {BehaviorFlags} from "../libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {ERC20ExtensionCore} from "./ERC20ExtensionCore.sol";

/**
 * @title ERC20TransferFee
 * @notice A transfer fee that is pre-computable.
 *
 * @dev The fee itself is the easy part. What makes fee-on-transfer tokens unintegratable is that a caller
 *      cannot answer "how much will actually arrive?" without trying it, so every protocol either wraps the
 *      call in balance snapshots or refuses the token. This module answers the question directly.
 *
 *      ## Rounding and direction
 *
 *      `fee = floor(amount * basisPoints / 10_000)`, withheld from the amount. Flooring rounds in the
 *      sender's favour, and the sender is the party who did not choose to pay a fee.
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

    /// @notice The highest fee rate this token will ever accept, as a compile-time constant. 10%.
    uint16 public constant MAX_FEE_BASIS_POINTS = 1_000;

    uint16 private _basisPoints;
    address private _feeVault;

    function __ERC20TransferFee_init() internal onlyInitializing {
        _registerExtension(ExtensionIds.TRANSFER_FEE, BehaviorFlags.FEE_ON_TRANSFER);
    }

    // -----------------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC20TransferFee
    function computeFee(address from, address to, uint256 amount) public view virtual returns (uint256) {
        if (from == address(0) || to == address(0)) return 0;

        uint16 basisPoints = _basisPoints;
        if (basisPoints == 0) return 0;

        return Math.mulDiv(amount, basisPoints, FEE_BASIS_POINT_DENOMINATOR);
    }

    /// @inheritdoc IERC20TransferFee
    function feeVault() public view virtual override returns (address) {
        return _feeVault;
    }

    /// @inheritdoc IERC20TransferFee
    function feeBasisPoints() public view virtual override returns (uint16) {
        return _basisPoints;
    }

    /// @inheritdoc ERC20ExtensionCore
    function _extensionData(bytes4 extensionId) internal view virtual override returns (bytes memory) {
        if (extensionId == ExtensionIds.TRANSFER_FEE) {
            return abi.encode(_basisPoints, _feeVault);
        }
        return super._extensionData(extensionId);
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

    /// @notice Sets the fee rate.
    function setFeeConfig(uint16 basisPoints) external virtual {
        _authorizeExtensionConfig(ExtensionIds.TRANSFER_FEE);
        if (basisPoints > MAX_FEE_BASIS_POINTS) {
            revert ERC20FeeBasisPointsTooHigh(basisPoints, MAX_FEE_BASIS_POINTS);
        }

        _basisPoints = basisPoints;

        emit FeeConfigUpdated(basisPoints);
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
}
