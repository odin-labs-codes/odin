// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {LaunchBeforeInitializeHookV1} from "./LaunchBeforeInitializeHookV1.sol";

/// @notice A permissionless exact-input router for canonical BERC launch pools.
/// @dev The contract has no owner, upgrade path, configurable fees, or asset rescue path.
contract BERCLaunchRouterV1 is IUnlockCallback, ReentrancyGuardTransient {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;

    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 200;

    IPoolManager public immutable POOL_MANAGER;
    LaunchBeforeInitializeHookV1 public immutable LAUNCH_HOOK;

    bool private _callbackActive;

    struct SwapCallbackData {
        PoolKey key;
        address payer;
        address recipient;
        uint256 amountIn;
        uint256 minAmountOut;
        bool zeroForOne;
    }

    event TokenBought(
        address indexed token,
        address indexed payer,
        address indexed recipient,
        uint256 nativeAmountIn,
        uint256 tokenAmountOut
    );
    event TokenSold(
        address indexed token,
        address indexed payer,
        address indexed recipient,
        uint256 tokenAmountIn,
        uint256 nativeAmountOut
    );

    error InvalidConfiguration();
    error InvalidSwap();
    error DeadlinePassed(uint256 deadline);
    error UnauthorizedCallback();
    error InvalidSwapDelta(int128 amount0, int128 amount1);
    error PartialSwap(uint256 expected, uint256 spent);
    error SlippageExceeded(uint256 minimum, uint256 received);

    constructor(IPoolManager poolManager_, LaunchBeforeInitializeHookV1 launchHook_) {
        if (
            address(poolManager_).code.length == 0 || address(launchHook_).code.length == 0
                || address(launchHook_.poolManager()) != address(poolManager_)
        ) revert InvalidConfiguration();
        POOL_MANAGER = poolManager_;
        LAUNCH_HOOK = launchHook_;
    }

    function buy(address token, address recipient, uint256 minTokensOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        _validateSwap(token, recipient, msg.value, deadline);
        tokensOut = _swap(
            SwapCallbackData({
                key: _canonicalPoolKey(token),
                payer: msg.sender,
                recipient: recipient,
                amountIn: msg.value,
                minAmountOut: minTokensOut,
                zeroForOne: true
            })
        );
        emit TokenBought(token, msg.sender, recipient, msg.value, tokensOut);
    }

    function sell(
        address token,
        uint256 tokenAmountIn,
        address payable recipient,
        uint256 minNativeOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 nativeOut) {
        _validateSwap(token, recipient, tokenAmountIn, deadline);
        nativeOut = _swap(
            SwapCallbackData({
                key: _canonicalPoolKey(token),
                payer: msg.sender,
                recipient: recipient,
                amountIn: tokenAmountIn,
                minAmountOut: minNativeOut,
                zeroForOne: false
            })
        );
        emit TokenSold(token, msg.sender, recipient, tokenAmountIn, nativeOut);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER) || !_callbackActive) revert UnauthorizedCallback();
        _callbackActive = false;

        SwapCallbackData memory callback = abi.decode(data, (SwapCallbackData));
        BalanceDelta delta = POOL_MANAGER.swap(
            callback.key,
            SwapParams({
                zeroForOne: callback.zeroForOne,
                amountSpecified: -SafeCast.toInt256(callback.amountIn),
                sqrtPriceLimitX96: callback.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        uint256 amountOut;

        if (callback.zeroForOne) {
            if (amount0 >= 0 || amount1 <= 0) revert InvalidSwapDelta(amount0, amount1);
            uint256 nativeSpent = SafeCast.toUint256(-int256(amount0));
            amountOut = SafeCast.toUint256(int256(amount1));
            _enforceAmounts(callback, nativeSpent, amountOut);
            uint256 settled = POOL_MANAGER.settle{value: nativeSpent}();
            if (settled != nativeSpent) revert PartialSwap(nativeSpent, settled);
            POOL_MANAGER.take(callback.key.currency1, callback.recipient, amountOut);
        } else {
            if (amount0 <= 0 || amount1 >= 0) revert InvalidSwapDelta(amount0, amount1);
            uint256 tokenSpent = SafeCast.toUint256(-int256(amount1));
            amountOut = SafeCast.toUint256(int256(amount0));
            _enforceAmounts(callback, tokenSpent, amountOut);
            POOL_MANAGER.sync(callback.key.currency1);
            IERC20(Currency.unwrap(callback.key.currency1))
                .safeTransferFrom(callback.payer, address(POOL_MANAGER), tokenSpent);
            uint256 settled = POOL_MANAGER.settle();
            if (settled != tokenSpent) revert PartialSwap(tokenSpent, settled);
            POOL_MANAGER.take(callback.key.currency0, callback.recipient, amountOut);
        }
        return abi.encode(amountOut);
    }

    function poolKey(address token) external view returns (PoolKey memory) {
        return _canonicalPoolKey(token);
    }

    function _swap(SwapCallbackData memory callback) private returns (uint256 amountOut) {
        _callbackActive = true;
        bytes memory result = POOL_MANAGER.unlock(abi.encode(callback));
        if (_callbackActive) revert UnauthorizedCallback();
        amountOut = abi.decode(result, (uint256));
    }

    function _validateSwap(address token, address recipient, uint256 amountIn, uint256 deadline) private view {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        if (
            token == address(0) || token.code.length == 0 || recipient == address(0) || amountIn == 0
                || amountIn > uint256(uint128(type(int128).max))
        ) revert InvalidSwap();
    }

    function _enforceAmounts(SwapCallbackData memory callback, uint256 amountSpent, uint256 amountOut) private pure {
        if (amountSpent != callback.amountIn) revert PartialSwap(callback.amountIn, amountSpent);
        if (amountOut < callback.minAmountOut) revert SlippageExceeded(callback.minAmountOut, amountOut);
    }

    function _canonicalPoolKey(address token) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(LAUNCH_HOOK))
        });
    }
}
