// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ERC721ExtensionCore} from "../../src/erc721/ERC721ExtensionCore.sol";
import {ERC721NonTransferable} from "../../src/erc721/ERC721NonTransferable.sol";
import {IERC721OperatorRestriction} from "../../src/interfaces/IERC721OperatorRestriction.sol";
import {BERCVerification} from "../../src/libraries/BERCVerification.sol";
import {BehaviorFlags} from "../../src/libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../../src/libraries/ExtensionIds.sol";
import {BERCFactoryV1} from "../../src/runtime/BERCFactoryV1.sol";
import {BERCNFTFactoryV1} from "../../src/runtime/BERCNFTFactoryV1.sol";
import {BERCNFTRuntimeV1} from "../../src/runtime/BERCNFTRuntimeV1.sol";
import {BERCRuntimeV1} from "../../src/runtime/BERCRuntimeV1.sol";

contract NFTRuntimeTest is Test {
    BERCNFTRuntimeV1 internal runtime;
    BERCNFTFactoryV1 internal factory;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        runtime = new BERCNFTRuntimeV1();
        factory = new BERCNFTFactoryV1(address(runtime));
    }

    // -----------------------------------------------------------------------------------------------
    // Verification — the claim this whole tier rests on
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev The point of building this at all. `BERCVerification` was written for fungible tokens and needed
     *      no change: it reads 45 bytes and compares an address, and has no opinion about what the code
     *      behind that address does. If this passes, the trust ladder is one mechanism rather than two.
     */
    function test_CollectionsVerifyAgainstTheRuntimeWithTheUnchangedLibrary() public {
        address collection = _deploy(_allCompatible());

        assertTrue(BERCVerification.isClonedFrom(collection, address(runtime)));
        assertEq(BERCVerification.implementationOf(collection), address(runtime));
    }

    /// @dev A clone the factory never made still verifies. The runtime is the anchor, not the factory.
    function test_AClonedRuntimeVerifiesEvenWithoutTheFactory() public {
        address rogue = _cloneOf(address(runtime));
        BERCNFTRuntimeV1(rogue).initialize("Rogue", "RGE", admin, new bytes4[](0));

        assertTrue(BERCVerification.isClonedFrom(rogue, address(runtime)));
        assertFalse(factory.isDeployedCollection(rogue), "and the factory index does not claim it");
    }

    /**
     * @dev The one that matters for a caller holding a single pinned address: a collection does not verify
     *      against the *fungible* runtime, and a token does not verify against this one. Same library, and
     *      the address is what separates them.
     */
    function test_TheTwoRuntimesDoNotVerifyAgainstEachOther() public {
        BERCRuntimeV1 tokenRuntime = new BERCRuntimeV1();
        BERCFactoryV1 tokenFactory = new BERCFactoryV1(address(tokenRuntime));

        address collection = _deploy(_allCompatible());
        address token = tokenFactory.deploy(
            BERCFactoryV1.TokenParams({
                name: "Token",
                symbol: "TKN",
                admin: admin,
                authorities: BERCFactoryV1.Authorities(
                    address(0), address(0), address(0), address(0), address(0), address(0)
                ),
                extensionIds: new bytes4[](0),
                feeVault: address(0),
                feeBasisPoints: 0,
                maximumFee: 0
            })
        );

        assertTrue(BERCVerification.isClonedFrom(collection, address(runtime)));
        assertTrue(BERCVerification.isClonedFrom(token, address(tokenRuntime)));
        assertFalse(BERCVerification.isClonedFrom(collection, address(tokenRuntime)), "cross-check must fail");
        assertFalse(BERCVerification.isClonedFrom(token, address(runtime)), "and in the other direction");
    }

    function test_TheRuntimeItselfDoesNotVerify() public view {
        assertFalse(BERCVerification.isClonedFrom(address(runtime), address(runtime)));
    }

    /// @dev A directly-initialised implementation would answer every call while passing no clone check.
    function test_TheRuntimeCannotBeInitialisedDirectly() public {
        vm.expectRevert();
        runtime.initialize("Direct", "DIR", admin, new bytes4[](0));
    }

    // -----------------------------------------------------------------------------------------------
    // Per-collection module gating
    // -----------------------------------------------------------------------------------------------

    /// @dev The runtime carries every module. A collection that installed none must behave as if it has none.
    function test_UninstalledModulesStayInert() public {
        BERCNFTRuntimeV1 bare = BERCNFTRuntimeV1(_deploy(new bytes4[](0)));

        vm.prank(admin);
        bare.mint(alice, 1);

        // No operator policy, no pause, no freeze: an ordinary transfer through an ordinary operator.
        vm.prank(alice);
        bare.setApprovalForAll(bob, true);
        vm.prank(bob);
        bare.transferFrom(alice, bob, 1);

        assertEq(bare.ownerOf(1), bob);
        assertEq(bare.behaviorFlags(), BehaviorFlags.MINTABLE | BehaviorFlags.SEIZABLE);
    }

    /// @dev And a collection that did install one is screened by it, on the same runtime code.
    function test_OperatorPolicyAppliesOnlyToCollectionsThatInstalledIt() public {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = ExtensionIds.NFT_OPERATOR_RESTRICTION;

        BERCNFTRuntimeV1 screened = BERCNFTRuntimeV1(_deploy(ids));
        BERCNFTRuntimeV1 open = BERCNFTRuntimeV1(_deploy(new bytes4[](0)));

        vm.startPrank(admin);
        screened.mint(alice, 1);
        open.mint(alice, 1);
        screened.setOperatorAllowlistEnforced(true);
        vm.stopPrank();

        vm.startPrank(alice);
        screened.setApprovalForAll(bob, true);
        open.setApprovalForAll(bob, true);
        vm.stopPrank();

        vm.prank(bob);
        open.transferFrom(alice, bob, 1);
        assertEq(open.ownerOf(1), bob, "the collection without the module is untouched");

        vm.expectRevert(abi.encodeWithSelector(IERC721OperatorRestriction.ERC721OperatorNotAllowed.selector, bob));
        vm.prank(bob);
        screened.transferFrom(alice, bob, 1);
    }

    function test_SoulboundAppliesOnlyToCollectionsThatInstalledIt() public {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = ExtensionIds.NFT_NON_TRANSFERABLE;

        BERCNFTRuntimeV1 soulbound = BERCNFTRuntimeV1(_deploy(ids));

        vm.prank(admin);
        soulbound.mint(alice, 1);

        vm.expectRevert(ERC721NonTransferable.ERC721TransfersNotSupported.selector);
        vm.prank(alice);
        soulbound.transferFrom(alice, bob, 1);
    }

    /// @dev A collection cannot be configured into an extension its own `extensions()` denies.
    function test_ConfiguringAnUninstalledModuleIsRejected() public {
        BERCNFTRuntimeV1 bare = BERCNFTRuntimeV1(_deploy(new bytes4[](0)));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721ExtensionCore.ERC721ExtensionNotEnabled.selector, ExtensionIds.NFT_OPERATOR_RESTRICTION
            )
        );
        vm.prank(admin);
        bare.setOperatorAllowlistEnforced(true);
    }

    /// @dev Metadata has to work on a clone, not just on a directly-deployed collection.
    function test_MetadataWorksThroughTheRuntime() public {
        BERCNFTRuntimeV1 collection = BERCNFTRuntimeV1(_deploy(_allCompatible()));

        vm.startPrank(admin);
        collection.mint(alice, 1);
        collection.setBaseURI("ipfs://runtime/");
        vm.stopPrank();

        assertEq(collection.tokenURI(1), "ipfs://runtime/1");
        assertEq(collection.baseURI(), "ipfs://runtime/");

        vm.prank(admin);
        collection.setTokenURI(1, "ipfs://one");
        assertEq(collection.tokenURI(1), "ipfs://one");

        vm.prank(admin);
        collection.freezeMetadata();
        assertTrue(collection.metadataFrozen());
    }

    function test_ACloneAnswersTheStandardInterfaces() public {
        BERCNFTRuntimeV1 collection = BERCNFTRuntimeV1(_deploy(_allCompatible()));

        assertTrue(collection.supportsInterface(type(IERC721).interfaceId));
        assertTrue(collection.supportsInterface(type(IERC165).interfaceId));
        assertTrue(collection.supportsInterface(type(IAccessControl).interfaceId));
        assertFalse(collection.supportsInterface(0xdeadbeef));
    }

    /**
     * @dev A module with nothing to report answers empty bytes rather than reverting, and getting there
     *      means walking the whole `_extensionData` chain past every module that does not claim the id.
     *      "Installed but unconfigured" has to stay distinguishable from "not installed", which reverts.
     */
    function test_AModuleWithNothingToReportAnswersEmptyBytes() public {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = ExtensionIds.NFT_NON_TRANSFERABLE;

        BERCNFTRuntimeV1 soulbound = BERCNFTRuntimeV1(_deploy(ids));

        assertEq(soulbound.extensionData(ExtensionIds.NFT_NON_TRANSFERABLE), "");

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721ExtensionCore.ERC721ExtensionNotEnabled.selector, ExtensionIds.NFT_MUTABLE_METADATA
            )
        );
        soulbound.extensionData(ExtensionIds.NFT_MUTABLE_METADATA);
    }

    // -----------------------------------------------------------------------------------------------
    // Factory
    // -----------------------------------------------------------------------------------------------

    function test_DeploysWithEveryCompatibleExtension() public {
        BERCNFTRuntimeV1 collection = BERCNFTRuntimeV1(_deploy(_allCompatible()));

        assertEq(
            collection.behaviorFlags(),
            BehaviorFlags.OPERATOR_RESTRICTED | BehaviorFlags.PAUSABLE | BehaviorFlags.BLOCKLIST
                | BehaviorFlags.METADATA_MUTABLE | BehaviorFlags.MINTABLE | BehaviorFlags.SEIZABLE
        );
        assertEq(collection.extensions().length, 3);
    }

    function test_RejectsSoulboundCombinedWithAnOperatorPolicy() public {
        bytes4[] memory ids = new bytes4[](2);
        ids[0] = ExtensionIds.NFT_NON_TRANSFERABLE;
        ids[1] = ExtensionIds.NFT_OPERATOR_RESTRICTION;

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721ExtensionCore.ERC721IncompatibleBehaviors.selector,
                BehaviorFlags.NON_TRANSFERABLE,
                BehaviorFlags.OPERATOR_RESTRICTED
            )
        );
        _deploy(ids);
    }

    function test_RejectsUnknownExtension() public {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = bytes4(keccak256("erc721.extension.imaginary"));

        vm.expectRevert(abi.encodeWithSelector(BERCNFTRuntimeV1.BERCNFTUnknownExtension.selector, ids[0]));
        _deploy(ids);
    }

    function test_RejectsDuplicateExtension() public {
        bytes4[] memory ids = new bytes4[](2);
        ids[0] = ExtensionIds.NFT_MUTABLE_METADATA;
        ids[1] = ExtensionIds.NFT_MUTABLE_METADATA;

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721ExtensionCore.ERC721ExtensionAlreadyRegistered.selector, ExtensionIds.NFT_MUTABLE_METADATA
            )
        );
        _deploy(ids);
    }

    function test_RejectsZeroAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(BERCNFTFactoryV1.BERCNFTInvalidAdmin.selector, address(0)));
        factory.deploy(_params(new bytes4[](0), address(0)));
    }

    function test_RejectsTheFactoryAsAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(BERCNFTFactoryV1.BERCNFTInvalidAdmin.selector, address(factory)));
        factory.deploy(_params(new bytes4[](0), address(factory)));
    }

    function test_RejectsARuntimeWithNoCode() public {
        vm.expectRevert(abi.encodeWithSelector(BERCNFTFactoryV1.BERCNFTInvalidRuntime.selector, address(0xdead)));
        new BERCNFTFactoryV1(address(0xdead));
    }

    /// @dev Configuration for a module the collection did not install is a mistake, not a no-op.
    function test_RejectsMetadataConfigWithoutTheMetadataExtension() public {
        BERCNFTFactoryV1.CollectionParams memory params = _params(new bytes4[](0), admin);
        params.baseURI = "ipfs://nowhere/";

        vm.expectRevert(BERCNFTFactoryV1.BERCNFTMetadataConfigWithoutMetadataExtension.selector);
        factory.deploy(params);
    }

    function test_RejectsOperatorConfigWithoutTheOperatorExtension() public {
        BERCNFTFactoryV1.CollectionParams memory params = _params(new bytes4[](0), admin);
        params.enforceOperatorAllowlist = true;

        vm.expectRevert(BERCNFTFactoryV1.BERCNFTOperatorConfigWithoutOperatorExtension.selector);
        factory.deploy(params);
    }

    function test_AppliesTheInitialConfiguration() public {
        BERCNFTFactoryV1.CollectionParams memory params = _params(_allCompatible(), admin);
        params.baseURI = "ipfs://collection/";
        params.enforceOperatorAllowlist = true;

        BERCNFTRuntimeV1 collection = BERCNFTRuntimeV1(factory.deploy(params));

        assertEq(collection.baseURI(), "ipfs://collection/");
        assertTrue(collection.operatorAllowlistEnforced());
        assertFalse(collection.isOperatorAllowed(bob), "and the allowlist is empty, as deployed");
    }

    // -----------------------------------------------------------------------------------------------
    // Role handover
    // -----------------------------------------------------------------------------------------------

    function test_AdminEndsWithEveryRoleAndTheFactoryWithNone() public {
        BERCNFTRuntimeV1 collection = BERCNFTRuntimeV1(_deploy(_allCompatible()));

        bytes32[6] memory roles = [
            collection.DEFAULT_ADMIN_ROLE(),
            collection.OPERATOR_POLICY_ROLE(),
            collection.RESTRICTION_ROLE(),
            collection.MINT_ROLE(),
            collection.SEIZE_ROLE(),
            collection.METADATA_ROLE()
        ];

        for (uint256 i = 0; i < roles.length; ++i) {
            assertTrue(collection.hasRole(roles[i], admin), "admin must hold every role");
            assertFalse(collection.hasRole(roles[i], address(factory)), "the factory must hold none");
        }
    }

    /**
     * @dev The split happens inside the deployment. A follow-up transaction would leave a window in which
     *      one key can pause the collection, rewrite every token's metadata and burn anything it likes.
     */
    function test_EachRoleCanBeHandedToItsOwnAuthorityAtCreation() public {
        address policy = makeAddr("policy");
        address curator = makeAddr("curator");

        BERCNFTFactoryV1.CollectionParams memory params = _params(_allCompatible(), admin);
        params.authorities.operatorPolicy = policy;
        params.authorities.metadata = curator;

        BERCNFTRuntimeV1 collection = BERCNFTRuntimeV1(factory.deploy(params));

        assertTrue(collection.hasRole(collection.OPERATOR_POLICY_ROLE(), policy));
        assertTrue(collection.hasRole(collection.METADATA_ROLE(), curator));
        assertTrue(collection.hasRole(collection.RESTRICTION_ROLE(), admin), "an unset field falls back to admin");
        assertFalse(collection.hasRole(collection.OPERATOR_POLICY_ROLE(), admin), "and the admin does not keep it");

        // The split is real, not just recorded.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, curator, collection.OPERATOR_POLICY_ROLE()
            )
        );
        vm.prank(curator);
        collection.setOperatorAllowlistEnforced(true);
    }

    function test_TheFactoryCannotConfigureACollectionItDeployed() public {
        BERCNFTRuntimeV1 collection = BERCNFTRuntimeV1(_deploy(_allCompatible()));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(factory), collection.METADATA_ROLE()
            )
        );
        vm.prank(address(factory));
        collection.setBaseURI("ipfs://hijacked/");
    }

    // -----------------------------------------------------------------------------------------------
    // Index and deterministic addresses
    // -----------------------------------------------------------------------------------------------

    function test_IndexRecordsEveryDeployment() public {
        address first = _deploy(new bytes4[](0));
        address second = _deploy(_allCompatible());

        assertEq(factory.collectionCount(), 2);
        assertEq(factory.collectionAt(0), first);
        assertEq(factory.collectionAt(1), second);
        assertTrue(factory.isDeployedCollection(first));
        assertFalse(factory.isDeployedCollection(address(this)));
    }

    function test_DeterministicAddressMatchesThePrediction() public {
        bytes32 salt = keccak256("collection-one");
        address predicted = factory.predictDeterministicAddress(address(this), salt);
        address deployed = factory.deployDeterministic(_params(new bytes4[](0), admin), salt);

        assertEq(deployed, predicted);
        assertTrue(BERCVerification.isClonedFrom(deployed, address(runtime)));
    }

    /// @dev Mixing the caller into the salt is what stops one deployer occupying another's address.
    function test_TheSameSaltFromTwoDeployersDoesNotCollide() public {
        bytes32 salt = keccak256("shared");

        vm.prank(alice);
        address fromAlice = factory.deployDeterministic(_params(new bytes4[](0), admin), salt);

        vm.prank(bob);
        address fromBob = factory.deployDeterministic(_params(new bytes4[](0), admin), salt);

        assertTrue(fromAlice != fromBob);
    }

    // -----------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------

    function _allCompatible() private pure returns (bytes4[] memory ids) {
        ids = new bytes4[](3);
        ids[0] = ExtensionIds.NFT_OPERATOR_RESTRICTION;
        ids[1] = ExtensionIds.NFT_TRANSFER_RESTRICTION;
        ids[2] = ExtensionIds.NFT_MUTABLE_METADATA;
    }

    function _params(bytes4[] memory ids, address collectionAdmin)
        private
        pure
        returns (BERCNFTFactoryV1.CollectionParams memory)
    {
        return BERCNFTFactoryV1.CollectionParams({
            name: "Collection",
            symbol: "COL",
            admin: collectionAdmin,
            authorities: BERCNFTFactoryV1.Authorities(address(0), address(0), address(0), address(0), address(0)),
            extensionIds: ids,
            baseURI: "",
            enforceOperatorAllowlist: false
        });
    }

    function _deploy(bytes4[] memory ids) private returns (address) {
        return factory.deploy(_params(ids, admin));
    }

    /// @dev A hand-rolled EIP-1167 clone, so the test does not depend on the factory to make one.
    function _cloneOf(address implementation) private returns (address instance) {
        bytes20 target = bytes20(implementation);
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), target)
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
    }
}
