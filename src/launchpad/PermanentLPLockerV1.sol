// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Permanently holds launch LP NFTs and splits collected LP fees 80% protocol / 20% creator.
/// @dev There is deliberately no NFT transfer, approval, position burn, liquidity removal, or rescue path.
contract PermanentLPLockerV1 is ReentrancyGuardTransient {
    using PositionInfoLibrary for PositionInfo;
    using SafeERC20 for IERC20;

    uint256 public constant CREATOR_SHARE = 20;
    uint256 public constant SHARE_DENOMINATOR = 100;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 200;
    int24 public constant TICK_LOWER = 76_000;
    int24 public constant TICK_UPPER = 191_200;

    IPositionManager public immutable POSITION_MANAGER;
    IPoolManager public immutable POOL_MANAGER;
    IHooks public immutable LAUNCH_HOOK;
    address public immutable PROTOCOL_TREASURY;
    address public immutable BINDER;
    address public factory;

    struct PositionRecord {
        address creator;
        address token;
        uint256 lockedDust;
        uint256 totalNativeCollected;
        uint256 totalTokenCollected;
        uint256 creatorNativeAccrued;
        uint256 creatorTokenAccrued;
        uint256 creatorNativeClaimed;
        uint256 creatorTokenClaimed;
        uint256 protocolNativeClaimed;
        uint256 protocolTokenClaimed;
    }

    mapping(uint256 tokenId => PositionRecord) public positions;

    event FactoryBound(address indexed factory);
    event PositionRegistered(
        uint256 indexed tokenId, address indexed token, address indexed creator, uint256 permanentlyLockedDust
    );
    event FeesCollected(
        uint256 indexed tokenId,
        uint256 nativeAmount,
        uint256 tokenAmount,
        uint256 creatorNativeAccrued,
        uint256 creatorTokenAccrued
    );
    event CreatorFeesClaimed(
        uint256 indexed tokenId,
        address indexed creator,
        address indexed recipient,
        uint256 nativeAmount,
        uint256 tokenAmount
    );
    event ProtocolFeesClaimed(
        uint256 indexed tokenId, address indexed treasury, uint256 nativeAmount, uint256 tokenAmount
    );

    error InvalidConfiguration();
    error FactoryAlreadyBound();
    error Unauthorized();
    error PositionAlreadyRegistered(uint256 tokenId);
    error InvalidPosition(uint256 tokenId);
    error UnknownPosition(uint256 tokenId);
    error InvalidRecipient();
    error UnexpectedNativeSender(address sender);

    constructor(IPositionManager positionManager_, IHooks launchHook_, address protocolTreasury_, address binder_) {
        if (
            address(positionManager_).code.length == 0 || address(launchHook_).code.length == 0
                || protocolTreasury_ == address(0) || binder_ == address(0)
        ) revert InvalidConfiguration();
        POSITION_MANAGER = positionManager_;
        POOL_MANAGER = positionManager_.poolManager();
        LAUNCH_HOOK = launchHook_;
        PROTOCOL_TREASURY = protocolTreasury_;
        BINDER = binder_;
    }

    receive() external payable {
        if (msg.sender != address(POSITION_MANAGER) && msg.sender != address(POOL_MANAGER)) {
            revert UnexpectedNativeSender(msg.sender);
        }
    }

    /// @notice Irreversibly binds the only factory that may register permanent positions.
    function bindFactory(address factory_) external {
        if (msg.sender != BINDER) revert Unauthorized();
        if (factory != address(0)) revert FactoryAlreadyBound();
        if (factory_.code.length == 0) revert InvalidConfiguration();
        factory = factory_;
        emit FactoryBound(factory_);
    }

    function register(uint256 tokenId, address token, address creator, uint256 lockedDust) external {
        if (msg.sender != factory || factory == address(0)) revert Unauthorized();
        if (token == address(0) || creator == address(0) || positions[tokenId].creator != address(0)) {
            revert PositionAlreadyRegistered(tokenId);
        }
        if (IERC721Owner(address(POSITION_MANAGER)).ownerOf(tokenId) != address(this)) {
            revert InvalidPosition(tokenId);
        }

        (PoolKey memory key, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != token
                || key.fee != LP_FEE || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(LAUNCH_HOOK)
                || info.tickLower() != TICK_LOWER || info.tickUpper() != TICK_UPPER
        ) revert InvalidPosition(tokenId);

        positions[tokenId].creator = creator;
        positions[tokenId].token = token;
        positions[tokenId].lockedDust = lockedDust;
        emit PositionRegistered(tokenId, token, creator, lockedDust);
    }

    /// @notice Realizes all currently owed fees without changing or unlocking the position's liquidity.
    function collect(uint256 tokenId) public nonReentrant returns (uint256 nativeAmount, uint256 tokenAmount) {
        return _collect(tokenId);
    }

    function _collect(uint256 tokenId) private returns (uint256 nativeAmount, uint256 tokenAmount) {
        PositionRecord storage position = positions[tokenId];
        if (position.creator == address(0)) revert UnknownPosition(tokenId);

        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = IERC20(position.token).balanceOf(address(this));

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(Currency.wrap(address(0)), Currency.wrap(position.token), address(this));
        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        nativeAmount = address(this).balance - nativeBefore;
        tokenAmount = IERC20(position.token).balanceOf(address(this)) - tokenBefore;
        position.totalNativeCollected += nativeAmount;
        position.totalTokenCollected += tokenAmount;

        // Cumulative entitlement avoids leaking rounding dust when fees are collected in many small calls.
        position.creatorNativeAccrued = position.totalNativeCollected * CREATOR_SHARE / SHARE_DENOMINATOR;
        position.creatorTokenAccrued = position.totalTokenCollected * CREATOR_SHARE / SHARE_DENOMINATOR;

        emit FeesCollected(
            tokenId, nativeAmount, tokenAmount, position.creatorNativeAccrued, position.creatorTokenAccrued
        );
    }

    function claimCreator(uint256 tokenId, address payable recipient)
        external
        nonReentrant
        returns (uint256 nativeAmount, uint256 tokenAmount)
    {
        return _claimCreator(tokenId, recipient);
    }

    /// @notice Realizes pending LP fees and pays the creator in one transaction.
    function collectAndClaimCreator(uint256 tokenId, address payable recipient)
        external
        nonReentrant
        returns (uint256 nativeAmount, uint256 tokenAmount)
    {
        _collect(tokenId);
        return _claimCreator(tokenId, recipient);
    }

    function _claimCreator(uint256 tokenId, address payable recipient)
        private
        returns (uint256 nativeAmount, uint256 tokenAmount)
    {
        PositionRecord storage position = positions[tokenId];
        if (msg.sender != position.creator || position.creator == address(0)) revert Unauthorized();
        if (recipient == address(0)) revert InvalidRecipient();

        nativeAmount = position.creatorNativeAccrued - position.creatorNativeClaimed;
        tokenAmount = position.creatorTokenAccrued - position.creatorTokenClaimed;
        position.creatorNativeClaimed += nativeAmount;
        position.creatorTokenClaimed += tokenAmount;
        _pay(position.token, recipient, nativeAmount, tokenAmount);
        emit CreatorFeesClaimed(tokenId, msg.sender, recipient, nativeAmount, tokenAmount);
    }

    /// @notice Permissionless upkeep that can only pay the immutable protocol treasury.
    function claimProtocol(uint256 tokenId)
        external
        nonReentrant
        returns (uint256 nativeAmount, uint256 tokenAmount)
    {
        return _claimProtocol(tokenId);
    }

    /// @notice Realizes pending LP fees and pays the immutable protocol treasury in one permissionless call.
    function collectAndClaimProtocol(uint256 tokenId)
        external
        nonReentrant
        returns (uint256 nativeAmount, uint256 tokenAmount)
    {
        _collect(tokenId);
        return _claimProtocol(tokenId);
    }

    function _claimProtocol(uint256 tokenId) private returns (uint256 nativeAmount, uint256 tokenAmount) {
        PositionRecord storage position = positions[tokenId];
        if (position.creator == address(0)) revert UnknownPosition(tokenId);

        nativeAmount = position.totalNativeCollected - position.creatorNativeAccrued - position.protocolNativeClaimed;
        tokenAmount = position.totalTokenCollected - position.creatorTokenAccrued - position.protocolTokenClaimed;
        position.protocolNativeClaimed += nativeAmount;
        position.protocolTokenClaimed += tokenAmount;
        _pay(position.token, payable(PROTOCOL_TREASURY), nativeAmount, tokenAmount);
        emit ProtocolFeesClaimed(tokenId, PROTOCOL_TREASURY, nativeAmount, tokenAmount);
    }

    function claimableCreator(uint256 tokenId) external view returns (uint256 nativeAmount, uint256 tokenAmount) {
        PositionRecord storage position = positions[tokenId];
        nativeAmount = position.creatorNativeAccrued - position.creatorNativeClaimed;
        tokenAmount = position.creatorTokenAccrued - position.creatorTokenClaimed;
    }

    function claimableProtocol(uint256 tokenId) external view returns (uint256 nativeAmount, uint256 tokenAmount) {
        PositionRecord storage position = positions[tokenId];
        nativeAmount = position.totalNativeCollected - position.creatorNativeAccrued - position.protocolNativeClaimed;
        tokenAmount = position.totalTokenCollected - position.creatorTokenAccrued - position.protocolTokenClaimed;
    }

    function _pay(address token, address payable recipient, uint256 nativeAmount, uint256 tokenAmount) private {
        if (nativeAmount != 0) {
            (bool success,) = recipient.call{value: nativeAmount}("");
            if (!success) revert InvalidRecipient();
        }
        if (tokenAmount != 0) IERC20(token).safeTransfer(recipient, tokenAmount);
    }
}
