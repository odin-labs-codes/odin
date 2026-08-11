// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {BERCVerification} from "../src/libraries/BERCVerification.sol";
import {ExtensionIds} from "../src/libraries/ExtensionIds.sol";
import {BERCFactoryV1} from "../src/runtime/BERCFactoryV1.sol";
import {BERCRuntimeV1} from "../src/runtime/BERCRuntimeV1.sol";

/**
 * @title DeployRuntime
 * @notice Deploys the shared runtime and its factory. Run once per chain, then never again.
 *
 * @dev The runtime address this prints is the number integrators pin. It is not discoverable and is not
 *      meant to be: verification works by comparing a token's bytecode against an address you already
 *      decided to trust, so publishing it — in this repo, in an audit report, wherever people will actually
 *      look — is the deployment's last step and the one that matters.
 *
 *      Nothing here is upgradeable and nothing has an owner. A second runtime is a second deployment with a
 *      second address, and existing tokens keep pointing at this one forever.
 */
contract DeployRuntime is Script {
    function run() external returns (BERCRuntimeV1 runtime, BERCFactoryV1 factory) {
        vm.startBroadcast();

        runtime = new BERCRuntimeV1();
        factory = new BERCFactoryV1(address(runtime));

        vm.stopBroadcast();

        console2.log("");
        console2.log("BERC runtime deployed");
        console2.log("  runtime        ", address(runtime));
        console2.log("  factory        ", address(factory));
        console2.log("  runtimeVersion ", runtime.RUNTIME_VERSION());
        console2.log("");
        console2.log("Integrators: pin the runtime address and verify tokens against it with");
        console2.log("BERCVerification.isClonedFrom(token, runtime). See docs/INTEGRATION.md.");
    }
}

/**
 * @title DeployCanonicalToken
 * @notice Deploys one verified token through an existing factory.
 *
 * @dev Environment:
 *        FACTORY            an already-deployed BERCFactoryV1. Optional: leaving it unset stands up a
 *                           fresh runtime and factory first, which is what makes this script runnable end
 *                           to end in CI. On a chain that already has a runtime, always pass it — a second
 *                           runtime is a second thing integrators have to trust.
 *        TOKEN_NAME         string
 *        TOKEN_SYMBOL       string
 *        ADMIN              receives DEFAULT_ADMIN_ROLE, and any operational role left unset below.
 *                           The factory rejects the zero address
 *        FEE_AUTHORITY, RESTRICTION_AUTHORITY, MINT_AUTHORITY, SEIZE_AUTHORITY, METADATA_AUTHORITY,
 *        HOOK_AUTHORITY     optional; each defaults to ADMIN
 *        WITH_METADATA      optional bool, default true
 *        WITH_FEE           optional bool, default true
 *        WITH_RESTRICTION   optional bool, default true
 *        WITH_HOOK          optional bool, default true
 *        FEE_VAULT          required when WITH_FEE
 *        FEE_BASIS_POINTS   required when WITH_FEE; range-checked before narrowing to uint16
 *        MAXIMUM_FEE        absolute per-transfer cap, required when WITH_FEE
 */
contract DeployCanonicalToken is Script {
    function run() external returns (address token) {
        address configured = vm.envOr("FACTORY", address(0));
        address admin = vm.envAddress("ADMIN");

        bool withMetadata = vm.envOr("WITH_METADATA", true);
        bool withFee = vm.envOr("WITH_FEE", true);
        bool withRestriction = vm.envOr("WITH_RESTRICTION", true);
        bool withHook = vm.envOr("WITH_HOOK", true);

        bytes4[] memory extensionIds = _collect(withMetadata, withFee, withRestriction, withHook);

        // Range-checked at full width. Narrowing first would turn 65,636 into 100 and deploy a token with
        // a rate nobody chose, since the truncated value passes every check downstream.
        uint16 basisPoints = 0;
        if (withFee) {
            uint256 raw = vm.envUint("FEE_BASIS_POINTS");
            require(raw <= type(uint16).max, "FEE_BASIS_POINTS does not fit in uint16");
            basisPoints = uint16(raw);
        }

        vm.startBroadcast();

        BERCFactoryV1 factory =
            configured == address(0) ? new BERCFactoryV1(address(new BERCRuntimeV1())) : BERCFactoryV1(configured);

        token = factory.deploy(
            BERCFactoryV1.TokenParams({
                name: vm.envString("TOKEN_NAME"),
                symbol: vm.envString("TOKEN_SYMBOL"),
                admin: admin,
                // Split at creation, exactly as the direct deployments do. Zero fields fall back to
                // `admin`, so a minimal environment still produces a working token.
                authorities: BERCFactoryV1.Authorities({
                    fee: vm.envOr("FEE_AUTHORITY", address(0)),
                    restriction: vm.envOr("RESTRICTION_AUTHORITY", address(0)),
                    mint: vm.envOr("MINT_AUTHORITY", address(0)),
                    seize: vm.envOr("SEIZE_AUTHORITY", address(0)),
                    metadata: vm.envOr("METADATA_AUTHORITY", address(0)),
                    hook: vm.envOr("HOOK_AUTHORITY", address(0))
                }),
                extensionIds: extensionIds,
                feeVault: withFee ? vm.envAddress("FEE_VAULT") : address(0),
                feeBasisPoints: basisPoints,
                maximumFee: withFee ? vm.envUint("MAXIMUM_FEE") : 0
            })
        );

        vm.stopBroadcast();

        // Proving it here means a broken deployment fails loudly rather than shipping an address that will
        // not verify for anyone else either.
        require(BERCVerification.isClonedFrom(token, factory.RUNTIME()), "deployed token does not verify");

        console2.log("");
        console2.log("Canonical BERC token deployed");
        console2.log("  token          ", token);
        console2.log("  runtime        ", factory.RUNTIME());
        console2.log("  extensions     ", extensionIds.length);
        console2.log("  verifies       ", true);
    }

    function _collect(bool withMetadata, bool withFee, bool withRestriction, bool withHook)
        private
        pure
        returns (bytes4[] memory extensionIds)
    {
        bytes4[] memory buffer = new bytes4[](4);
        uint256 count = 0;

        if (withMetadata) buffer[count++] = ExtensionIds.ONCHAIN_METADATA;
        if (withFee) buffer[count++] = ExtensionIds.TRANSFER_FEE;
        if (withRestriction) buffer[count++] = ExtensionIds.TRANSFER_RESTRICTION;
        if (withHook) buffer[count++] = ExtensionIds.TRANSFER_HOOK;

        extensionIds = new bytes4[](count);
        for (uint256 i = 0; i < count; ++i) {
            extensionIds[i] = buffer[i];
        }
    }
}
