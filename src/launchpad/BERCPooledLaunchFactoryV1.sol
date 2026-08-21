// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {ExtensionIds} from "../libraries/ExtensionIds.sol";
import {BERCFactoryV1} from "../runtime/BERCFactoryV1.sol";
import {BERCRuntimeV1} from "../runtime/BERCRuntimeV1.sol";
import {LaunchBeforeInitializeHookV1} from "./LaunchBeforeInitializeHookV1.sol";
import {PermanentLPLockerV1} from "./PermanentLPLockerV1.sol";

/// @notice Atomically creates a fixed-supply BERC token, its canonical v4 pool, permanent LP, and optional first buy.
contract BERCPooledLaunchFactoryV1 is IUnlockCallback, ReentrancyGuardTransient {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 public constant TOKEN_SUPPLY = 1_000_000_000 ether;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 200;
    int24 public constant TICK_LOWER = 76_000;
    int24 public constant TICK_UPPER = 191_200;
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_SYMBOL_BYTES = 16;
    uint256 public constant MAX_METADATA_URI_BYTES = 256;

    BERCFactoryV1 public immutable BERC_FACTORY;
    IPoolManager public immutable POOL_MANAGER;
    IPositionManager public immutable POSITION_MANAGER;
    IAllowanceTransfer public immutable PERMIT2;
    LaunchBeforeInitializeHookV1 public immutable LAUNCH_HOOK;
    PermanentLPLockerV1 public immutable LP_LOCKER;

    bool private _initialBuyCallbackActive;

    struct LaunchRequest {
        string name;
        string symbol;
        string metadataURI;
        bytes32 salt;
        uint256 minInitialTokensOut;
        uint256 deadline;
    }

    struct LaunchRecord {
        address creator;
        uint256 positionTokenId;
        uint128 liquidity;
        uint256 launchedAt;
    }

    struct InitialBuyCallbackData {
        PoolKey key;
        address recipient;
        uint256 nativeAmountIn;
        uint256 minTokensOut;
    }

    struct LaunchResult {
        address token;
        address creator;
        PoolId poolId;
        uint256 positionTokenId;
        uint128 liquidity;
        uint256 lockedDust;
        uint256 initialNativeIn;
        uint256 initialTokensOut;
    }

    mapping(address token => LaunchRecord) public launches;

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        PoolId indexed poolId,
        uint256 positionTokenId,
        uint128 liquidity,
        uint256 permanentlyLockedDust,
        uint256 initialNativeIn,
        uint256 initialTokensOut,
        string metadataURI
    );

    error InvalidConfiguration();
    error FactoryWiringIncomplete();
    error DeadlinePassed(uint256 deadline);
    error InvalidName();
    error InvalidSymbol();
    error InvalidMetadataURI();
    error InvalidInitialBuy();
    error UnauthorizedCallback();
    error InvalidSwapDelta(int128 amount0, int128 amount1);
    error PartialInitialBuy(uint256 expected, uint256 spent);
    error InitialBuySlippage(uint256 minimum, uint256 received);
    error RoleRenunciationFailed();

    constructor(
        BERCFactoryV1 bercFactory_,
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        LaunchBeforeInitializeHookV1 launchHook_,
        PermanentLPLockerV1 lpLocker_
    ) {
        if (
            address(bercFactory_).code.length == 0 || address(poolManager_).code.length == 0
                || address(positionManager_).code.length == 0 || address(permit2_).code.length == 0
                || address(launchHook_).code.length == 0 || address(lpLocker_).code.length == 0
                || address(positionManager_.poolManager()) != address(poolManager_)
                || address(launchHook_.poolManager()) != address(poolManager_)
                || address(lpLocker_.POSITION_MANAGER()) != address(positionManager_)
                || address(lpLocker_.LAUNCH_HOOK()) != address(launchHook_)
        ) revert InvalidConfiguration();

        BERC_FACTORY = bercFactory_;
        POOL_MANAGER = poolManager_;
        POSITION_MANAGER = positionManager_;
        PERMIT2 = permit2_;
        LAUNCH_HOOK = launchHook_;
        LP_LOCKER = lpLocker_;
    }

    function launch(LaunchRequest calldata request)
        external
        payable
        nonReentrant
        returns (address token, uint256 positionTokenId, uint256 initialTokensOut)
    {
        _validateWiring();
        _validateRequest(request);

        LaunchResult memory result;
        result.creator = msg.sender;
        result.initialNativeIn = msg.value;
        result.token = _deployToken(request);
        token = result.token;

        PoolKey memory key = _canonicalPoolKey(token);
        result.poolId = key.toId();
        POOL_MANAGER.initialize(key, LAUNCH_HOOK.OPENING_SQRT_PRICE_X96());
        (result.positionTokenId, result.liquidity, result.lockedDust) =
            _mintAndLockPosition(key, token, msg.sender, request.deadline);
        positionTokenId = result.positionTokenId;

        if (msg.value != 0) {
            result.initialTokensOut = _initialBuy(key, msg.sender, msg.value, request.minInitialTokensOut);
        }
        initialTokensOut = result.initialTokensOut;

        _permanentlyRenounceTokenRoles(token);
        _recordAndEmit(result, request.metadataURI);
    }

    function _deployToken(LaunchRequest calldata request) private returns (address token) {
        bytes4[] memory extensionIds = new bytes4[](1);
        extensionIds[0] = ExtensionIds.ONCHAIN_METADATA;
        BERCFactoryV1.Authorities memory authorities;
        BERCFactoryV1.TokenParams memory tokenParams = BERCFactoryV1.TokenParams({
            name: request.name,
            symbol: request.symbol,
            admin: address(this),
            authorities: authorities,
            extensionIds: extensionIds,
            feeVault: address(0),
            feeBasisPoints: 0,
            maximumFee: 0
        });

        bytes32 creatorSalt = keccak256(abi.encode(msg.sender, request.salt));
        token = BERC_FACTORY.deployDeterministic(tokenParams, creatorSalt);
        BERCRuntimeV1 runtime = BERCRuntimeV1(token);
        runtime.setTokenURI(request.metadataURI);
        runtime.mint(address(this), TOKEN_SUPPLY);
    }

    function _mintAndLockPosition(PoolKey memory key, address token, address creator, uint256 deadline)
        private
        returns (uint256 positionTokenId, uint128 liquidity, uint256 lockedDust)
    {
        liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(TICK_UPPER), TOKEN_SUPPLY
        );
        positionTokenId = POSITION_MANAGER.nextTokenId();
        _mintPermanentPosition(key, token, liquidity, positionTokenId, deadline);

        lockedDust = IERC20(token).balanceOf(address(this));
        if (lockedDust != 0) IERC20(token).safeTransfer(address(LP_LOCKER), lockedDust);
        LP_LOCKER.register(positionTokenId, token, creator, lockedDust);
    }

    function _permanentlyRenounceTokenRoles(address token) private {
        BERCRuntimeV1 runtime = BERCRuntimeV1(token);
        runtime.burnAdminPrivileges();
        runtime.renounceAllRoles();
        if (!runtime.adminPrivilegesBurned() || runtime.hasRole(runtime.MINT_ROLE(), address(this))) {
            revert RoleRenunciationFailed();
        }
    }

    function _recordAndEmit(LaunchResult memory result, string calldata metadataURI) private {
        launches[result.token] = LaunchRecord({
            creator: result.creator,
            positionTokenId: result.positionTokenId,
            liquidity: result.liquidity,
            launchedAt: block.timestamp
        });
        emit TokenLaunched(
            result.token,
            result.creator,
            result.poolId,
            result.positionTokenId,
            result.liquidity,
            result.lockedDust,
            result.initialNativeIn,
            result.initialTokensOut,
            metadataURI
        );
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER) || !_initialBuyCallbackActive) revert UnauthorizedCallback();
        _initialBuyCallbackActive = false;

        InitialBuyCallbackData memory callback = abi.decode(data, (InitialBuyCallbackData));
        BalanceDelta delta = POOL_MANAGER.swap(
            callback.key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -SafeCast.toInt256(callback.nativeAmountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            bytes("")
        );
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        if (amount0 >= 0 || amount1 <= 0) revert InvalidSwapDelta(amount0, amount1);

        uint256 nativeSpent = SafeCast.toUint256(-int256(amount0));
        uint256 tokensOut = SafeCast.toUint256(int256(amount1));
        if (nativeSpent != callback.nativeAmountIn) revert PartialInitialBuy(callback.nativeAmountIn, nativeSpent);
        if (tokensOut < callback.minTokensOut) revert InitialBuySlippage(callback.minTokensOut, tokensOut);

        uint256 settled = POOL_MANAGER.settle{value: nativeSpent}();
        if (settled != nativeSpent) revert PartialInitialBuy(nativeSpent, settled);
        POOL_MANAGER.take(callback.key.currency1, callback.recipient, tokensOut);
        return abi.encode(tokensOut);
    }

    function predictTokenAddress(address creator, bytes32 salt) external view returns (address) {
        return BERC_FACTORY.predictDeterministicAddress(address(this), keccak256(abi.encode(creator, salt)));
    }

    function poolKey(address token) external view returns (PoolKey memory) {
        return _canonicalPoolKey(token);
    }

    /// @notice Quotes the atomic first buy before its pool exists.
    /// @dev Frontends should pass ProtocolFeeLibrary.MAX_PROTOCOL_FEE for a conservative minimum-output bound.
    function quoteInitialBuy(uint256 nativeAmountIn, uint16 protocolFee)
        external
        pure
        returns (uint256 tokensOut, uint256 nativeAmountSpent, uint160 sqrtPriceAfterX96)
    {
        if (protocolFee > ProtocolFeeLibrary.MAX_PROTOCOL_FEE || nativeAmountIn > uint256(uint128(type(int128).max)))
        {
            revert InvalidInitialBuy();
        }
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(TICK_UPPER), TOKEN_SUPPLY
        );
        uint256 amountIn;
        uint256 feeAmount;
        (sqrtPriceAfterX96, amountIn, tokensOut, feeAmount) = SwapMath.computeSwapStep(
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            liquidity,
            -SafeCast.toInt256(nativeAmountIn),
            ProtocolFeeLibrary.calculateSwapFee(protocolFee, LP_FEE)
        );
        nativeAmountSpent = amountIn + feeAmount;
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

    function _mintPermanentPosition(
        PoolKey memory key,
        address token,
        uint128 liquidity,
        uint256 expectedTokenId,
        uint256 deadline
    ) private {
        IERC20(token).forceApprove(address(PERMIT2), TOKEN_SUPPLY);
        PERMIT2.approve(
            token, address(POSITION_MANAGER), SafeCast.toUint160(TOKEN_SUPPLY), SafeCast.toUint48(block.timestamp)
        );

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            TICK_LOWER,
            TICK_UPPER,
            uint256(liquidity),
            uint128(0),
            SafeCast.toUint128(TOKEN_SUPPLY),
            address(LP_LOCKER),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, params), deadline);
        if (POSITION_MANAGER.nextTokenId() != expectedTokenId + 1) revert InvalidConfiguration();

        PERMIT2.approve(token, address(POSITION_MANAGER), 0, 0);
        IERC20(token).forceApprove(address(PERMIT2), 0);
    }

    function _initialBuy(PoolKey memory key, address recipient, uint256 amountIn, uint256 minTokensOut)
        private
        returns (uint256 tokensOut)
    {
        if (amountIn > uint256(uint128(type(int128).max))) revert InvalidInitialBuy();
        _initialBuyCallbackActive = true;
        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(
                InitialBuyCallbackData({
                    key: key, recipient: recipient, nativeAmountIn: amountIn, minTokensOut: minTokensOut
                })
            )
        );
        if (_initialBuyCallbackActive) revert UnauthorizedCallback();
        tokensOut = abi.decode(result, (uint256));
    }

    function _validateWiring() private view {
        if (LAUNCH_HOOK.factory() != address(this) || LP_LOCKER.factory() != address(this)) {
            revert FactoryWiringIncomplete();
        }
    }

    function _validateRequest(LaunchRequest calldata request) private view {
        if (block.timestamp > request.deadline) revert DeadlinePassed(request.deadline);
        uint256 nameLength = bytes(request.name).length;
        if (nameLength == 0 || nameLength > MAX_NAME_BYTES) revert InvalidName();
        uint256 symbolLength = bytes(request.symbol).length;
        if (symbolLength == 0 || symbolLength > MAX_SYMBOL_BYTES) revert InvalidSymbol();
        if (!_isIPFSURI(request.metadataURI)) revert InvalidMetadataURI();
        if (msg.value == 0 && request.minInitialTokensOut != 0) revert InvalidInitialBuy();
    }

    function _isIPFSURI(string calldata value) private pure returns (bool) {
        bytes calldata uri = bytes(value);
        if (uri.length < 8 || uri.length > MAX_METADATA_URI_BYTES) return false;
        return uri[0] == "i" && uri[1] == "p" && uri[2] == "f" && uri[3] == "s" && uri[4] == ":" && uri[5] == "/"
            && uri[6] == "/";
    }
}
