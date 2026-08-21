// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {BERCLaunchRouterV1} from "../src/launchpad/BERCLaunchRouterV1.sol";
import {BERCPooledLaunchFactoryV1} from "../src/launchpad/BERCPooledLaunchFactoryV1.sol";
import {LaunchBeforeInitializeHookV1} from "../src/launchpad/LaunchBeforeInitializeHookV1.sol";
import {PermanentLPLockerV1} from "../src/launchpad/PermanentLPLockerV1.sol";
import {BERCFactoryV1} from "../src/runtime/BERCFactoryV1.sol";
import {BERCRuntimeV1} from "../src/runtime/BERCRuntimeV1.sol";

/// @notice Deploys and irreversibly wires the Robinhood Chain launch contracts.
/// @dev Use a local Foundry keystore account. This script never reads a raw private key environment variable.
contract DeployLaunchpad is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IPositionManager internal constant POSITION_MANAGER =
        IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    IAllowanceTransfer internal constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    struct Deployment {
        BERCRuntimeV1 runtime;
        BERCFactoryV1 bercFactory;
        LaunchBeforeInitializeHookV1 hook;
        PermanentLPLockerV1 locker;
        BERCPooledLaunchFactoryV1 launchFactory;
        BERCLaunchRouterV1 launchRouter;
    }

    function run() external returns (Deployment memory deployment) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "DeployLaunchpad: wrong chain");
        require(CREATE2_DEPLOYER.code.length != 0, "DeployLaunchpad: CREATE2 deployer missing");

        address deployer = vm.envAddress("DEPLOYER");
        address treasury = vm.envAddress("PROTOCOL_TREASURY");
        require(deployer != address(0) && treasury != address(0), "DeployLaunchpad: zero address");
        require(address(POOL_MANAGER).code.length != 0, "DeployLaunchpad: PoolManager missing");
        require(address(POSITION_MANAGER).code.length != 0, "DeployLaunchpad: PositionManager missing");
        require(address(PERMIT2).code.length != 0, "DeployLaunchpad: Permit2 missing");
        require(address(POSITION_MANAGER.poolManager()) == address(POOL_MANAGER), "DeployLaunchpad: manager mismatch");

        bytes memory hookArguments = abi.encode(POOL_MANAGER, deployer);
        (address expectedHook, bytes32 hookSalt) = HookMiner.find(
            CREATE2_DEPLOYER,
            uint160(Hooks.BEFORE_INITIALIZE_FLAG),
            type(LaunchBeforeInitializeHookV1).creationCode,
            hookArguments
        );

        vm.startBroadcast();
        deployment.runtime = new BERCRuntimeV1();
        deployment.bercFactory = new BERCFactoryV1(address(deployment.runtime));
        deployment.hook = new LaunchBeforeInitializeHookV1{salt: hookSalt}(POOL_MANAGER, deployer);
        require(address(deployment.hook) == expectedHook, "DeployLaunchpad: hook address mismatch");

        deployment.locker = new PermanentLPLockerV1(POSITION_MANAGER, deployment.hook, treasury, deployer);
        deployment.launchFactory = new BERCPooledLaunchFactoryV1(
            deployment.bercFactory, POOL_MANAGER, POSITION_MANAGER, PERMIT2, deployment.hook, deployment.locker
        );
        deployment.launchRouter = new BERCLaunchRouterV1(POOL_MANAGER, deployment.hook);
        deployment.hook.bindFactory(address(deployment.launchFactory));
        deployment.locker.bindFactory(address(deployment.launchFactory));
        vm.stopBroadcast();

        require(deployment.hook.factory() == address(deployment.launchFactory), "DeployLaunchpad: hook unbound");
        require(deployment.locker.factory() == address(deployment.launchFactory), "DeployLaunchpad: locker unbound");
        require(
            address(deployment.launchRouter.POOL_MANAGER()) == address(POOL_MANAGER)
                && address(deployment.launchRouter.LAUNCH_HOOK()) == address(deployment.hook),
            "DeployLaunchpad: router mismatch"
        );
        require(
            uint160(address(deployment.hook)) & Hooks.ALL_HOOK_MASK == Hooks.BEFORE_INITIALIZE_FLAG,
            "DeployLaunchpad: invalid hook flags"
        );

        console2.log("");
        console2.log("Robinhood Chain launchpad deployed and permanently wired");
        console2.log("  BERC runtime   ", address(deployment.runtime));
        console2.log("  BERC factory   ", address(deployment.bercFactory));
        console2.log("  init hook      ", address(deployment.hook));
        console2.log("  LP locker      ", address(deployment.locker));
        console2.log("  launch factory ", address(deployment.launchFactory));
        console2.log("  launch router  ", address(deployment.launchRouter));
        console2.log("  treasury       ", treasury);
        console2.log("  runtime code hash:");
        console2.logBytes32(address(deployment.runtime).codehash);
        console2.log("  BERC factory code hash:");
        console2.logBytes32(address(deployment.bercFactory).codehash);
        console2.log("  hook code hash:");
        console2.logBytes32(address(deployment.hook).codehash);
        console2.log("  locker code hash:");
        console2.logBytes32(address(deployment.locker).codehash);
        console2.log("  factory code hash:");
        console2.logBytes32(address(deployment.launchFactory).codehash);
        console2.log("  router code hash:");
        console2.logBytes32(address(deployment.launchRouter).codehash);
    }
}
