// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {BERCVerification} from "../src/libraries/BERCVerification.sol";
import {ExtensionIds} from "../src/libraries/ExtensionIds.sol";
import {BERCNFTFactoryV1} from "../src/runtime/BERCNFTFactoryV1.sol";
import {BERCNFTRuntimeV1} from "../src/runtime/BERCNFTRuntimeV1.sol";

/**
 * @title DeployNFTRuntime
 * @notice Deploys the shared non-fungible runtime and its factory. Run once per chain, then never again.
 *
 * @dev The runtime address this prints is the number integrators pin, and it is a *different* number from
 *      the fungible runtime's. Both are checked with the same `BERCVerification.isClonedFrom` call, so a
 *      caller that pins the wrong one gets a clean `false` rather than a wrong answer — but they get it for
 *      every collection, which looks like the library is broken. Publish both addresses together.
 */
contract DeployNFTRuntime is Script {
    function run() external returns (BERCNFTRuntimeV1 runtime, BERCNFTFactoryV1 factory) {
        vm.startBroadcast();

        runtime = new BERCNFTRuntimeV1();
        factory = new BERCNFTFactoryV1(address(runtime));

        vm.stopBroadcast();

        console2.log("");
        console2.log("BERC NFT runtime deployed");
        console2.log("  runtime        ", address(runtime));
        console2.log("  factory        ", address(factory));
        console2.log("  runtimeVersion ", runtime.RUNTIME_VERSION());
        console2.log("");
        console2.log("Integrators: pin the runtime address and verify collections against it with");
        console2.log("BERCVerification.isClonedFrom(collection, runtime). See docs/INTEGRATION.md.");
    }
}

/**
 * @title DeployCanonicalCollection
 * @notice Deploys one verified collection through an existing factory.
 *
 * @dev Environment:
 *        NFT_FACTORY        an already-deployed BERCNFTFactoryV1. Optional: leaving it unset stands up a
 *                           fresh runtime and factory first, which is what makes this runnable end to end
 *                           in CI. On a chain that already has a runtime, always pass it.
 *        TOKEN_NAME         string
 *        TOKEN_SYMBOL       string
 *        ADMIN              receives DEFAULT_ADMIN_ROLE, and any role left unset below. Rejected if zero
 *        WITH_OPERATOR_POLICY   optional bool, default true
 *        WITH_RESTRICTION       optional bool, default true
 *        WITH_METADATA          optional bool, default true
 *        WITH_SOULBOUND         optional bool, default false. Contradicts WITH_OPERATOR_POLICY
 *        BASE_URI               optional; requires WITH_METADATA
 *        ENFORCE_OPERATOR_ALLOWLIST  optional bool, default false; requires WITH_OPERATOR_POLICY
 *        OPERATOR_POLICY_AUTHORITY, RESTRICTION_AUTHORITY, MINT_AUTHORITY, SEIZE_AUTHORITY,
 *        METADATA_AUTHORITY optional; each defaults to ADMIN
 */
contract DeployCanonicalCollection is Script {
    function run() external returns (address collection) {
        address configured = vm.envOr("NFT_FACTORY", address(0));
        address admin = vm.envAddress("ADMIN");

        bool withOperatorPolicy = vm.envOr("WITH_OPERATOR_POLICY", true);
        bool withRestriction = vm.envOr("WITH_RESTRICTION", true);
        bool withMetadata = vm.envOr("WITH_METADATA", true);
        bool withSoulbound = vm.envOr("WITH_SOULBOUND", false);

        bytes4[] memory extensionIds = _collect(withOperatorPolicy, withRestriction, withMetadata, withSoulbound);

        vm.startBroadcast();

        BERCNFTFactoryV1 factory = configured == address(0)
            ? new BERCNFTFactoryV1(address(new BERCNFTRuntimeV1()))
            : BERCNFTFactoryV1(configured);

        collection = factory.deploy(
            BERCNFTFactoryV1.CollectionParams({
                name: vm.envString("TOKEN_NAME"),
                symbol: vm.envString("TOKEN_SYMBOL"),
                admin: admin,
                // Split at creation, exactly as the fungible deployments do. Zero fields fall back to
                // `admin`, so a minimal environment still produces a working collection.
                authorities: BERCNFTFactoryV1.Authorities({
                    operatorPolicy: vm.envOr("OPERATOR_POLICY_AUTHORITY", address(0)),
                    restriction: vm.envOr("RESTRICTION_AUTHORITY", address(0)),
                    mint: vm.envOr("MINT_AUTHORITY", address(0)),
                    seize: vm.envOr("SEIZE_AUTHORITY", address(0)),
                    metadata: vm.envOr("METADATA_AUTHORITY", address(0))
                }),
                extensionIds: extensionIds,
                baseURI: withMetadata ? vm.envOr("BASE_URI", string("")) : "",
                enforceOperatorAllowlist: withOperatorPolicy && vm.envOr("ENFORCE_OPERATOR_ALLOWLIST", false)
            })
        );

        vm.stopBroadcast();

        // Proving it here means a broken deployment fails loudly rather than shipping an address that will
        // not verify for anyone else either.
        require(BERCVerification.isClonedFrom(collection, factory.RUNTIME()), "deployed collection does not verify");

        console2.log("");
        console2.log("Canonical BERC collection deployed");
        console2.log("  collection     ", collection);
        console2.log("  runtime        ", factory.RUNTIME());
        console2.log("  extensions     ", extensionIds.length);
        console2.log("  verifies       ", true);
    }

    function _collect(bool withOperatorPolicy, bool withRestriction, bool withMetadata, bool withSoulbound)
        private
        pure
        returns (bytes4[] memory extensionIds)
    {
        bytes4[] memory buffer = new bytes4[](4);
        uint256 count = 0;

        if (withOperatorPolicy) buffer[count++] = ExtensionIds.NFT_OPERATOR_RESTRICTION;
        if (withRestriction) buffer[count++] = ExtensionIds.NFT_TRANSFER_RESTRICTION;
        if (withMetadata) buffer[count++] = ExtensionIds.NFT_MUTABLE_METADATA;
        if (withSoulbound) buffer[count++] = ExtensionIds.NFT_NON_TRANSFERABLE;

        extensionIds = new bytes4[](count);
        for (uint256 i = 0; i < count; ++i) {
            extensionIds[i] = buffer[i];
        }
    }
}
