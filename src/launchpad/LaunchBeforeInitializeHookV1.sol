// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/// @notice Restricts creation of the canonical launch pool to the launch factory and its fixed economics.
/// @dev The address must be mined so its low 14 bits equal Hooks.BEFORE_INITIALIZE_FLAG (0x2000).
contract LaunchBeforeInitializeHookV1 is BaseHook {
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 200;
    int24 public constant OPENING_TICK = 191_200;
    uint160 public immutable OPENING_SQRT_PRICE_X96;

    address public immutable BINDER;
    address public factory;

    event FactoryBound(address indexed factory);

    error InvalidBinder();
    error FactoryAlreadyBound();
    error InvalidFactory(address factory);
    error UnauthorizedInitializer(address sender);
    error InvalidLaunchPool();
    error InvalidOpeningPrice(uint160 supplied);

    constructor(IPoolManager poolManager_, address binder_) BaseHook(poolManager_) {
        if (binder_ == address(0)) revert InvalidBinder();
        BINDER = binder_;
        OPENING_SQRT_PRICE_X96 = TickMath.getSqrtPriceAtTick(OPENING_TICK);
    }

    /// @notice Irreversibly binds the only contract allowed to initialize pools through this hook.
    function bindFactory(address factory_) external {
        if (msg.sender != BINDER) revert InvalidBinder();
        if (factory != address(0)) revert FactoryAlreadyBound();
        if (factory_.code.length == 0) revert InvalidFactory(factory_);
        factory = factory_;
        emit FactoryBound(factory_);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != factory || factory == address(0)) revert UnauthorizedInitializer(sender);
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) == address(0)
                || key.fee != LP_FEE || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this)
        ) revert InvalidLaunchPool();
        if (sqrtPriceX96 != OPENING_SQRT_PRICE_X96) revert InvalidOpeningPrice(sqrtPriceX96);
        return IHooks.beforeInitialize.selector;
    }
}
