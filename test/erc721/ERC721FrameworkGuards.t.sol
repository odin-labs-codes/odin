// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import {ERC721ExtensionCore} from "../../src/erc721/ERC721ExtensionCore.sol";
import {ERC721NonTransferable} from "../../src/erc721/ERC721NonTransferable.sol";
import {ERC721OperatorRestriction} from "../../src/erc721/ERC721OperatorRestriction.sol";
import {ExtendedNFT, SoulboundNFT} from "../../src/erc721/ExtendedNFT.sol";
import {ExtendedNFTBase} from "../../src/erc721/ExtendedNFTBase.sol";
import {BehaviorFlags} from "../../src/libraries/BehaviorFlags.sol";
import {ExtensionIds} from "../../src/libraries/ExtensionIds.sol";

/**
 * @title ContradictoryNFT
 * @notice An assembly that declares both that its tokens can never move and that it screens the operators
 *         who move them.
 *
 * @dev Nothing stops someone writing this, which is why the framework has to. A collection declaring both
 *      would advertise a marketplace policy that can never apply, and an integrator reading
 *      `OPERATOR_RESTRICTED` would go and populate an allowlist that does nothing.
 */
contract ContradictoryNFT is ExtendedNFTBase, ERC721NonTransferable, ERC721OperatorRestriction {
    constructor() {
        _init();
        _disableInitializers();
    }

    function _init() private initializer {
        __ExtendedNFTBase_init("Contradictory", "BAD", address(this));
        __ERC721NonTransferable_init();
        __ERC721OperatorRestriction_init();
        _sealExtensions();
    }

    function _checkTransferAllowed(address from, address to, uint256 tokenId, address auth)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ERC721NonTransferable, ERC721OperatorRestriction)
    {
        super._checkTransferAllowed(from, to, tokenId, auth);
    }

    function _extensionData(bytes4 extensionId)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ERC721OperatorRestriction)
        returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _authorizeExtensionConfig(bytes4 extensionId)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ExtendedNFTBase)
    {
        super._authorizeExtensionConfig(extensionId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ExtendedNFTBase, ERC721Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

/// @dev Declares a bit the vocabulary has never assigned a meaning to.
contract UnknownFlagNFT is ExtendedNFTBase {
    constructor() {
        _init();
        _disableInitializers();
    }

    function _init() private initializer {
        __ExtendedNFTBase_init("Unknown", "UNK", address(this));
        _declareBehavior(1 << 200);
        _sealExtensions();
    }
}

/// @dev Never seals, so it has no discovery surface at all rather than an unvalidated one.
contract UnsealedNFT is ExtendedNFTBase {
    constructor() {
        _init();
        _disableInitializers();
    }

    function _init() private initializer {
        __ExtendedNFTBase_init("Unsealed", "UNS", address(this));
    }
}

/// @dev Registers the same module twice.
contract DoubleRegisterNFT is ExtendedNFTBase, ERC721OperatorRestriction {
    constructor() {
        _init();
        _disableInitializers();
    }

    function _init() private initializer {
        __ExtendedNFTBase_init("Double", "DBL", address(this));
        __ERC721OperatorRestriction_init();
        __ERC721OperatorRestriction_init();
        _sealExtensions();
    }

    function _checkTransferAllowed(address from, address to, uint256 tokenId, address auth)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ERC721OperatorRestriction)
    {
        super._checkTransferAllowed(from, to, tokenId, auth);
    }

    function _extensionData(bytes4 extensionId)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ERC721OperatorRestriction)
        returns (bytes memory)
    {
        return super._extensionData(extensionId);
    }

    function _authorizeExtensionConfig(bytes4 extensionId)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ExtendedNFTBase)
    {
        super._authorizeExtensionConfig(extensionId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ExtendedNFTBase, ERC721Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

/// @dev Adds a module after the set was frozen, which would make a cached extension list a lie.
contract RegisterAfterSealNFT is ExtendedNFTBase, ERC721NonTransferable {
    constructor() {
        _init();
        _disableInitializers();
    }

    function _init() private initializer {
        __ExtendedNFTBase_init("Late", "LATE", address(this));
        _sealExtensions();
        __ERC721NonTransferable_init();
    }

    function _checkTransferAllowed(address from, address to, uint256 tokenId, address auth)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ERC721NonTransferable)
    {
        super._checkTransferAllowed(from, to, tokenId, auth);
    }

    function _authorizeExtensionConfig(bytes4 extensionId)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ExtendedNFTBase)
    {
        super._authorizeExtensionConfig(extensionId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ExtendedNFTBase, ERC721Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

/// @dev Declares behaviour after the set was frozen, which would make a cached flag word a lie.
contract DeclareAfterSealNFT is ExtendedNFTBase {
    constructor() {
        _init();
        _disableInitializers();
    }

    function _init() private initializer {
        __ExtendedNFTBase_init("Late", "LATE", address(this));
        _sealExtensions();
        _declareBehavior(BehaviorFlags.PAUSABLE);
    }
}

/// @dev Seals twice, which would re-run the consistency check against an already-published word.
contract DoubleSealNFT is ExtendedNFTBase {
    constructor() {
        _init();
        _disableInitializers();
    }

    function _init() private initializer {
        __ExtendedNFTBase_init("Twice", "TWCE", address(this));
        _sealExtensions();
        _sealExtensions();
    }
}

/**
 * @title UnmappedModuleNFT
 * @notice Installs a module the base assembly has no role for, and exposes a setter that routes to it.
 *
 * @dev The case {ExtendedNFTBase-_authorizeExtensionConfig} closes with its final `revert`. An assembly
 *      that adds a module without deciding who may configure it would otherwise fall through the dispatch
 *      and authorise nobody-in-particular, which is the one outcome worse than a missing feature.
 */
contract UnmappedModuleNFT is ExtendedNFTBase, ERC721NonTransferable {
    constructor() {
        _init();
        _disableInitializers();
    }

    function _init() private initializer {
        __ExtendedNFTBase_init("Unmapped", "UNM", address(this));
        __ERC721NonTransferable_init();
        _sealExtensions();
    }

    /// @dev Installed here, but with no role mapped: reaches the dispatch's final `revert`.
    function configureInstalled() external view {
        _authorizeExtensionConfig(ExtensionIds.NFT_NON_TRANSFERABLE);
    }

    /// @dev Never installed here: rejected one level earlier, by the core.
    function configureUninstalled() external view {
        _authorizeExtensionConfig(ExtensionIds.NFT_OPERATOR_RESTRICTION);
    }

    function _checkTransferAllowed(address from, address to, uint256 tokenId, address auth)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ERC721NonTransferable)
    {
        super._checkTransferAllowed(from, to, tokenId, auth);
    }

    function _authorizeExtensionConfig(bytes4 extensionId)
        internal
        view
        virtual
        override(ERC721ExtensionCore, ExtendedNFTBase)
    {
        super._authorizeExtensionConfig(extensionId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ExtendedNFTBase, ERC721Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

/**
 * @title ERC721FrameworkGuardsTest
 * @notice The guard rails only a third party assembling their own collection can trip, plus the constants
 *         that are published outside the source tree.
 */
contract ERC721FrameworkGuardsTest is Test {
    // -----------------------------------------------------------------------------------------------
    // Forbidden combinations
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev The shared vocabulary decides this, not the non-fungible core — which is why an integrator can
     *      run `BehaviorFlags.conflictingPair` against a collection they did not deploy and reach the same
     *      verdict the constructor did.
     */
    function test_RevertWhen_NonTransferableIsCombinedWithAnOperatorPolicy() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721ExtensionCore.ERC721IncompatibleBehaviors.selector,
                BehaviorFlags.NON_TRANSFERABLE,
                BehaviorFlags.OPERATOR_RESTRICTED
            )
        );
        new ContradictoryNFT();
    }

    function test_TheVocabularyAgreesWithTheConstructor() public pure {
        (uint256 first, uint256 second) =
            BehaviorFlags.conflictingPair(BehaviorFlags.NON_TRANSFERABLE | BehaviorFlags.OPERATOR_RESTRICTED);
        assertEq(first, BehaviorFlags.NON_TRANSFERABLE);
        assertEq(second, BehaviorFlags.OPERATOR_RESTRICTED);
    }

    /// @dev An operator policy on its own is not a contradiction, and neither is soulbound on its own.
    function test_EachReferenceCollectionIsSelfConsistent() public pure {
        (uint256 a,) = BehaviorFlags.conflictingPair(
            BehaviorFlags.OPERATOR_RESTRICTED | BehaviorFlags.MINTABLE | BehaviorFlags.SEIZABLE
        );
        (uint256 b,) = BehaviorFlags.conflictingPair(
            BehaviorFlags.NON_TRANSFERABLE | BehaviorFlags.MINTABLE | BehaviorFlags.SEIZABLE
        );
        assertEq(a, 0);
        assertEq(b, 0);
    }

    function test_RevertWhen_ModuleIsRegisteredTwice() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721ExtensionCore.ERC721ExtensionAlreadyRegistered.selector, ExtensionIds.NFT_OPERATOR_RESTRICTION
            )
        );
        new DoubleRegisterNFT();
    }

    function test_RevertWhen_ModuleIsRegisteredAfterSealing() public {
        vm.expectRevert(ERC721ExtensionCore.ERC721ExtensionSetSealed.selector);
        new RegisterAfterSealNFT();
    }

    function test_RevertWhen_BehaviourIsDeclaredAfterSealing() public {
        vm.expectRevert(ERC721ExtensionCore.ERC721ExtensionSetSealed.selector);
        new DeclareAfterSealNFT();
    }

    function test_RevertWhen_SealedTwice() public {
        vm.expectRevert(ERC721ExtensionCore.ERC721ExtensionSetSealed.selector);
        new DoubleSealNFT();
    }

    /// @dev Installed, but with no role behind it. The dispatch refuses rather than authorising anyone.
    function test_RevertWhen_AnInstalledModuleHasNoRoleMapped() public {
        UnmappedModuleNFT unmapped = new UnmappedModuleNFT();

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721ExtensionCore.ERC721ExtensionNotEnabled.selector, ExtensionIds.NFT_NON_TRANSFERABLE
            )
        );
        unmapped.configureInstalled();
    }

    /**
     * @dev The same error from one level earlier. A setter naming an extension the collection never
     *      installed is refused by the core, before any assembly's role dispatch runs — which is what
     *      keeps a module's configuration from being written into storage nothing reads.
     */
    function test_RevertWhen_ConfiguringAnExtensionThatWasNeverInstalled() public {
        UnmappedModuleNFT unmapped = new UnmappedModuleNFT();

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC721ExtensionCore.ERC721ExtensionNotEnabled.selector, ExtensionIds.NFT_OPERATOR_RESTRICTION
            )
        );
        unmapped.configureUninstalled();
    }

    /// @dev A module with nothing to report answers empty bytes, not a revert. That is the base case.
    function test_InstalledButUnconfiguredReportsEmptyBytes() public {
        SoulboundNFT soulbound = new SoulboundNFT("Soulbound", "SOUL", address(this));
        assertEq(soulbound.extensionData(ExtensionIds.NFT_NON_TRANSFERABLE), "");
    }

    // -----------------------------------------------------------------------------------------------
    // Registration
    // -----------------------------------------------------------------------------------------------

    function test_RevertWhen_AnUnassignedBehaviourBitIsDeclared() public {
        vm.expectRevert(
            abi.encodeWithSelector(ERC721ExtensionCore.ERC721UnknownBehaviorFlag.selector, uint256(1) << 200)
        );
        new UnknownFlagNFT();
    }

    /// @dev No discovery surface is a loud failure; a surface that was never validated is a quiet one.
    function test_RevertWhen_DiscoveryIsReadBeforeSealing() public {
        UnsealedNFT unsealed = new UnsealedNFT();

        vm.expectRevert(ERC721ExtensionCore.ERC721ExtensionSetNotSealed.selector);
        unsealed.behaviorFlags();

        vm.expectRevert(ERC721ExtensionCore.ERC721ExtensionSetNotSealed.selector);
        unsealed.extensions();
    }

    // -----------------------------------------------------------------------------------------------
    // Published constants
    // -----------------------------------------------------------------------------------------------

    /// @dev The token type is part of the name, so these can never collide with the fungible identifiers.
    function test_ExtensionIdsAreTheTopFourBytesOfTheirName() public pure {
        assertEq(
            _b32(ExtensionIds.NFT_OPERATOR_RESTRICTION), _name32("erc721.extension.operatorRestriction"), "operator"
        );
        assertEq(_b32(ExtensionIds.NFT_NON_TRANSFERABLE), _name32("erc721.extension.nonTransferable"), "soulbound");
    }

    /**
     * @dev Reads the live collection's storage at the computed address and checks the value found there is
     *      what the struct layout says should be, which catches a wrong literal *and* a reordered struct.
     */
    function test_RegistryStorageLivesAtItsNamespace() public {
        ExtendedNFT nft = new ExtendedNFT("Extended", "EXT", address(this));

        // First field is `bytes4[] ids`, so the base slot holds the array length: three modules registered.
        assertEq(uint256(vm.load(address(nft), _erc7201("berc.storage.ERC721ExtensionRegistry"))), 3);
    }

    function test_OperatorRestrictionStorageLivesAtItsNamespace() public {
        ExtendedNFT nft = new ExtendedNFT("Extended", "EXT", address(this));
        nft.setOperatorAllowlistEnforced(true);

        // First field is `bool enforced`.
        assertEq(uint256(vm.load(address(nft), _erc7201("berc.storage.ERC721OperatorRestriction"))), 1);
    }

    /// @dev Two registries in one framework, and a collision would silently corrupt both.
    function test_NonFungibleNamespacesAreDistinctFromTheFungibleOnes() public pure {
        assertTrue(_erc7201("berc.storage.ERC721ExtensionRegistry") != _erc7201("berc.storage.ExtensionRegistry"));
        assertTrue(
            _erc7201("berc.storage.ERC721OperatorRestriction") != _erc7201("berc.storage.ERC721ExtensionRegistry")
        );
    }

    function _erc7201(string memory namespace) private pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(namespace))) - 1)) & ~bytes32(uint256(0xff));
    }

    function _name32(string memory name) private pure returns (bytes32) {
        return _b32(bytes4(keccak256(bytes(name))));
    }

    function _b32(bytes4 value) private pure returns (bytes32) {
        return bytes32(value);
    }
}
