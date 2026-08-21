// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Test} from "forge-std/Test.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BERCLaunchRouterV1} from "../../src/launchpad/BERCLaunchRouterV1.sol";
import {BERCPooledLaunchFactoryV1} from "../../src/launchpad/BERCPooledLaunchFactoryV1.sol";
import {LaunchBeforeInitializeHookV1} from "../../src/launchpad/LaunchBeforeInitializeHookV1.sol";
import {PermanentLPLockerV1} from "../../src/launchpad/PermanentLPLockerV1.sol";
import {BERCFactoryV1} from "../../src/runtime/BERCFactoryV1.sol";
import {BERCRuntimeV1} from "../../src/runtime/BERCRuntimeV1.sol";

contract BERCPooledLaunchTest is Test {
    string internal constant ROBINHOOD_RPC = "https://rpc.mainnet.chain.robinhood.com";
    IPoolManager internal constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IPositionManager internal constant POSITION_MANAGER =
        IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    IAllowanceTransfer internal constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant TREASURY = address(0xB377E2);

    BERCRuntimeV1 internal runtimeImplementation;
    BERCFactoryV1 internal bercFactory;
    LaunchBeforeInitializeHookV1 internal launchHook;
    PermanentLPLockerV1 internal locker;
    BERCPooledLaunchFactoryV1 internal launchFactory;
    BERCLaunchRouterV1 internal launchRouter;

    function setUp() public {
        vm.createSelectFork(ROBINHOOD_RPC);

        runtimeImplementation = new BERCRuntimeV1();
        bercFactory = new BERCFactoryV1(address(runtimeImplementation));

        address hookAddress = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG));
        deployCodeTo(
            "launchpad/LaunchBeforeInitializeHookV1.sol:LaunchBeforeInitializeHookV1",
            abi.encode(MANAGER, address(this)),
            hookAddress
        );
        launchHook = LaunchBeforeInitializeHookV1(hookAddress);
        locker = new PermanentLPLockerV1(POSITION_MANAGER, launchHook, TREASURY, address(this));
        launchFactory =
            new BERCPooledLaunchFactoryV1(bercFactory, MANAGER, POSITION_MANAGER, PERMIT2, launchHook, locker);
        launchRouter = new BERCLaunchRouterV1(MANAGER, launchHook);
        launchHook.bindFactory(address(launchFactory));
        locker.bindFactory(address(launchFactory));
        vm.deal(CREATOR, 10 ether);
    }

    function testRouterBuysCanonicalLaunchToken() public {
        vm.prank(CREATOR);
        (address token,,) = launchFactory.launch(_request(bytes32("router-buy"), 0));

        address buyer = address(0xB0B);
        vm.deal(buyer, 1 ether);
        uint256 nativeBefore = buyer.balance;
        vm.prank(buyer);
        uint256 tokensOut = launchRouter.buy{value: 0.1 ether}(token, buyer, 1, block.timestamp);

        assertGt(tokensOut, 0);
        assertEq(IERC20(token).balanceOf(buyer), tokensOut);
        assertEq(nativeBefore - buyer.balance, 0.1 ether);
        assertEq(address(launchRouter).balance, 0);
        assertEq(IERC20(token).balanceOf(address(launchRouter)), 0);
    }

    function testRouterSellsCanonicalLaunchToken() public {
        BERCPooledLaunchFactoryV1.LaunchRequest memory request = _request(bytes32("router-sell"), 1);
        vm.prank(CREATOR);
        (address token,, uint256 initialTokens) = launchFactory.launch{value: 1 ether}(request);
        uint256 tokensToSell = initialTokens / 2;

        vm.prank(CREATOR);
        IERC20(token).approve(address(launchRouter), tokensToSell);
        uint256 nativeBefore = CREATOR.balance;
        vm.prank(CREATOR);
        uint256 nativeOut = launchRouter.sell(token, tokensToSell, payable(CREATOR), 1, block.timestamp);

        assertGt(nativeOut, 0);
        assertEq(CREATOR.balance - nativeBefore, nativeOut);
        assertEq(IERC20(token).balanceOf(CREATOR), initialTokens - tokensToSell);
        assertEq(IERC20(token).balanceOf(address(launchRouter)), 0);
        assertEq(address(launchRouter).balance, 0);
    }

    function testRouterSlippageRevertsAtomically() public {
        vm.prank(CREATOR);
        (address token,,) = launchFactory.launch(_request(bytes32("router-slippage"), 0));

        vm.expectPartialRevert(BERCLaunchRouterV1.SlippageExceeded.selector);
        vm.prank(CREATOR);
        launchRouter.buy{value: 0.1 ether}(token, CREATOR, type(uint256).max, block.timestamp);
        assertEq(IERC20(token).balanceOf(CREATOR), 0);
    }

    function testLaunchLocksPositionAndBurnsEveryAuthority() public {
        BERCPooledLaunchFactoryV1.LaunchRequest memory request = _request(bytes32("first"), 0);
        address predicted = launchFactory.predictTokenAddress(CREATOR, request.salt);

        vm.prank(CREATOR);
        (address token, uint256 positionTokenId, uint256 initialTokensOut) = launchFactory.launch(request);

        assertEq(token, predicted);
        assertEq(initialTokensOut, 0);
        assertEq(BERCRuntimeV1(token).totalSupply(), launchFactory.TOKEN_SUPPLY());
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(positionTokenId), address(locker));
        assertGt(POSITION_MANAGER.getPositionLiquidity(positionTokenId), 0);
        assertEq(launchHook.OPENING_SQRT_PRICE_X96(), TickMath.getSqrtPriceAtTick(launchHook.OPENING_TICK()));

        BERCRuntimeV1 launched = BERCRuntimeV1(token);
        assertTrue(launched.adminPrivilegesBurned());
        assertFalse(launched.hasRole(launched.DEFAULT_ADMIN_ROLE(), address(launchFactory)));
        assertFalse(launched.hasRole(launched.MINT_ROLE(), address(launchFactory)));
        assertFalse(launched.hasRole(launched.SEIZE_ROLE(), address(launchFactory)));
        assertFalse(launched.hasRole(launched.METADATA_ROLE(), address(launchFactory)));
        assertFalse(launched.hasRole(launched.FEE_CONFIG_ROLE(), address(launchFactory)));
        assertFalse(launched.hasRole(launched.RESTRICTION_ROLE(), address(launchFactory)));
        assertFalse(launched.hasRole(launched.HOOK_CONFIG_ROLE(), address(launchFactory)));
    }

    function testOptionalInitialBuyIsAtomicAndPaysCreator() public {
        uint256 initialBuy = 0.01 ether;
        BERCPooledLaunchFactoryV1.LaunchRequest memory request = _request(bytes32("buy"), 1);
        (uint256 conservativeQuote, uint256 spent,) = launchFactory.quoteInitialBuy(initialBuy, 1_000);
        request.minInitialTokensOut = conservativeQuote * 95 / 100;

        vm.prank(CREATOR);
        (address token,, uint256 tokensOut) = launchFactory.launch{value: initialBuy}(request);

        assertEq(spent, initialBuy);
        assertGe(tokensOut, conservativeQuote);
        assertGt(tokensOut, 0);
        assertEq(IERC20(token).balanceOf(CREATOR), tokensOut);
        assertEq(address(launchFactory).balance, 0);
        assertEq(BERCRuntimeV1(token).totalSupply(), launchFactory.TOKEN_SUPPLY());
    }

    function testCollectedInitialBuyLPFeesSplitCumulativelyEightyTwenty() public {
        BERCPooledLaunchFactoryV1.LaunchRequest memory request = _request(bytes32("fees"), 1);
        vm.prank(CREATOR);
        (, uint256 positionTokenId,) = launchFactory.launch{value: 1 ether}(request);

        (uint256 nativeCollected, uint256 tokenCollected) = locker.collect(positionTokenId);
        assertGt(nativeCollected, 0);

        (uint256 creatorNative, uint256 creatorToken) = locker.claimableCreator(positionTokenId);
        (uint256 protocolNative, uint256 protocolToken) = locker.claimableProtocol(positionTokenId);
        assertEq(creatorNative, nativeCollected * 20 / 100);
        assertEq(creatorToken, tokenCollected * 20 / 100);
        assertEq(creatorNative + protocolNative, nativeCollected);
        assertEq(creatorToken + protocolToken, tokenCollected);

        uint256 creatorNativeBefore = CREATOR.balance;
        uint256 creatorTokenBefore = IERC20(_positionToken(positionTokenId)).balanceOf(CREATOR);
        vm.prank(CREATOR);
        locker.claimCreator(positionTokenId, payable(CREATOR));
        assertEq(CREATOR.balance - creatorNativeBefore, creatorNative);
        assertEq(IERC20(_positionToken(positionTokenId)).balanceOf(CREATOR) - creatorTokenBefore, creatorToken);

        uint256 treasuryNativeBefore = TREASURY.balance;
        uint256 treasuryTokenBefore = IERC20(_positionToken(positionTokenId)).balanceOf(TREASURY);
        locker.claimProtocol(positionTokenId);
        assertEq(TREASURY.balance - treasuryNativeBefore, protocolNative);
        assertEq(IERC20(_positionToken(positionTokenId)).balanceOf(TREASURY) - treasuryTokenBefore, protocolToken);
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(positionTokenId), address(locker));
    }

    function testCreatorCanCollectAndClaimInOneCall() public {
        BERCPooledLaunchFactoryV1.LaunchRequest memory request = _request(bytes32("one-call-fees"), 1);
        vm.prank(CREATOR);
        (, uint256 positionTokenId,) = launchFactory.launch{value: 0.1 ether}(request);

        uint256 beforeBalance = CREATOR.balance;
        vm.prank(CREATOR);
        (uint256 nativeAmount,) = locker.collectAndClaimCreator(positionTokenId, payable(CREATOR));

        assertGt(nativeAmount, 0);
        assertEq(CREATOR.balance - beforeBalance, nativeAmount);
        (uint256 nativeClaimable, uint256 tokenClaimable) = locker.claimableCreator(positionTokenId);
        assertEq(nativeClaimable, 0);
        assertEq(tokenClaimable, 0);
    }

    function testAnyoneCanCollectAndPayProtocolOnlyToTreasury() public {
        BERCPooledLaunchFactoryV1.LaunchRequest memory request = _request(bytes32("one-call-protocol"), 1);
        vm.prank(CREATOR);
        (, uint256 positionTokenId,) = launchFactory.launch{value: 0.1 ether}(request);

        uint256 treasuryBefore = TREASURY.balance;
        vm.prank(address(0xB0B));
        (uint256 nativeAmount,) = locker.collectAndClaimProtocol(positionTokenId);

        assertGt(nativeAmount, 0);
        assertEq(TREASURY.balance - treasuryBefore, nativeAmount);
        assertEq(address(0xB0B).balance, 0);
        (uint256 nativeClaimable, uint256 tokenClaimable) = locker.claimableProtocol(positionTokenId);
        assertEq(nativeClaimable, 0);
        assertEq(tokenClaimable, 0);
    }

    function testHookRejectsAnyInitializerOtherThanBoundFactory() public {
        MockERC20 token = new MockERC20("Other", "OTHER", 18);
        PoolKey memory otherKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: launchFactory.LP_FEE(),
            tickSpacing: launchFactory.TICK_SPACING(),
            hooks: IHooks(address(launchHook))
        });

        uint160 openingSqrtPriceX96 = launchHook.OPENING_SQRT_PRICE_X96();
        vm.expectRevert();
        MANAGER.initialize(otherKey, openingSqrtPriceX96);
    }

    function testLaunchRevertsBeforeOneTimeWiring() public {
        address secondHookAddress = address(uint160(uint160(Hooks.BEFORE_INITIALIZE_FLAG) | (uint160(1) << 14)));
        deployCodeTo(
            "launchpad/LaunchBeforeInitializeHookV1.sol:LaunchBeforeInitializeHookV1",
            abi.encode(MANAGER, address(this)),
            secondHookAddress
        );
        LaunchBeforeInitializeHookV1 secondHook = LaunchBeforeInitializeHookV1(secondHookAddress);
        PermanentLPLockerV1 secondLocker =
            new PermanentLPLockerV1(POSITION_MANAGER, secondHook, TREASURY, address(this));
        BERCPooledLaunchFactoryV1 unbound =
            new BERCPooledLaunchFactoryV1(bercFactory, MANAGER, POSITION_MANAGER, PERMIT2, secondHook, secondLocker);

        vm.expectRevert(BERCPooledLaunchFactoryV1.FactoryWiringIncomplete.selector);
        vm.prank(CREATOR);
        unbound.launch(_request(bytes32("unbound"), 0));
    }

    function _request(bytes32 salt, uint256 minTokensOut)
        private
        view
        returns (BERCPooledLaunchFactoryV1.LaunchRequest memory)
    {
        return BERCPooledLaunchFactoryV1.LaunchRequest({
            name: "Better Launch",
            symbol: "BLCH",
            metadataURI: "ipfs://bafybeigdyrzt",
            salt: salt,
            minInitialTokensOut: minTokensOut,
            deadline: block.timestamp + 1 hours
        });
    }

    function _positionToken(uint256 tokenId) private view returns (address token) {
        (PoolKey memory positionKey,) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        token = Currency.unwrap(positionKey.currency1);
    }
}
