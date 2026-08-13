// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Test} from "forge-std/Test.sol";

import {ExtendedToken} from "../../src/ExtendedToken.sol";
import {ERC20ExtensionCore} from "../../src/extensions/ERC20ExtensionCore.sol";
import {BERCVerification} from "../../src/libraries/BERCVerification.sol";
import {BERCFactoryV1} from "../../src/runtime/BERCFactoryV1.sol";
import {BERCRuntimeV1} from "../../src/runtime/BERCRuntimeV1.sol";
import {PlainERC20} from "../mocks/PlainERC20.sol";

/**
 * @title VerificationTest
 * @notice The negative cases are the point. Anything that verifies a token it should not is a hole an
 *         integrator would fall through, so most of this file is things that must *fail*.
 */
contract VerificationTest is Test {
    BERCRuntimeV1 internal runtime;
    BERCFactoryV1 internal factory;

    address internal admin = makeAddr("admin");

    function setUp() public {
        runtime = new BERCRuntimeV1();
        factory = new BERCFactoryV1(address(runtime));
    }

    // -----------------------------------------------------------------------------------------------
    // What verifies
    // -----------------------------------------------------------------------------------------------

    function test_FactoryDeployedTokenVerifies() public {
        address token = _deployViaFactory();

        assertTrue(BERCVerification.isClonedFrom(token, address(runtime)));
        assertEq(BERCVerification.implementationOf(token), address(runtime));
    }

    /**
     * @dev Provenance is not the claim. A clone made without the factory runs the same audited code, so it
     *      verifies exactly as a factory-made one does — and it should, because the guarantee being offered
     *      is about which code executes, never about who deployed it.
     */
    function test_TokenClonedWithoutTheFactoryAlsoVerifies() public {
        address token = Clones.clone(address(runtime));
        BERCRuntimeV1(token).initialize("Manual", "MAN", admin, new bytes4[](0));

        assertTrue(BERCVerification.isClonedFrom(token, address(runtime)));
        assertFalse(factory.isDeployedToken(token), "the factory's index does not know it");
    }

    // -----------------------------------------------------------------------------------------------
    // What must not
    // -----------------------------------------------------------------------------------------------

    function test_EOADoesNotVerify() public {
        address nobody = makeAddr("nobody");

        assertFalse(BERCVerification.isClonedFrom(nobody, address(runtime)));
        assertEq(BERCVerification.implementationOf(nobody), address(0));
    }

    function test_PlainERC20DoesNotVerify() public {
        address plain = address(new PlainERC20("Plain", "PLN"));

        assertFalse(BERCVerification.isClonedFrom(plain, address(runtime)));
        assertEq(BERCVerification.implementationOf(plain), address(0));
    }

    /// @dev A self-declared token is a real BERC token and still must not pass the verified bar.
    function test_SelfDeclaredExtendedTokenDoesNotVerify() public {
        address selfDeclared = address(new ExtendedToken("Self", "SELF", admin));

        assertFalse(BERCVerification.isClonedFrom(selfDeclared, address(runtime)));
    }

    /// @dev The runtime is the implementation, not a proxy to it.
    function test_TheRuntimeItselfDoesNotVerify() public view {
        assertFalse(BERCVerification.isClonedFrom(address(runtime), address(runtime)));
    }

    /**
     * @dev The case the whole library exists for: a minimal proxy is cheap to deploy against *any*
     *      implementation, so matching the 1167 shape cannot be enough on its own.
     */
    function test_CloneOfAnotherImplementationDoesNotVerify() public {
        address impostorImplementation = address(new PlainERC20("Plain", "PLN"));
        address impostor = Clones.clone(impostorImplementation);

        assertFalse(BERCVerification.isClonedFrom(impostor, address(runtime)));
        assertEq(
            BERCVerification.implementationOf(impostor), impostorImplementation, "it is a clone, just not of ours"
        );
    }

    /**
     * @dev Length alone is not identity. These two are the same size as a minimal proxy and name the real
     *      runtime, and differ from one only in a byte of the prologue or the epilogue — which is exactly
     *      what an attacker would build, since anything that passed here would be arbitrary code wearing a
     *      verified token's face.
     */
    function test_A45ByteImpostorWithAWrongPrologueDoesNotVerify() public {
        address impostor = makeAddr("wrongPrologue");
        // Final byte of the prologue changed from 0x73 (PUSH20) to 0x00.
        vm.etch(
            impostor,
            abi.encodePacked(hex"363d3d373d3d3d363d00", address(runtime), hex"5af43d82803e903d91602b57fd5bf3")
        );

        assertEq(impostor.code.length, 45, "the fixture must be the right length to be a fair test");
        assertEq(BERCVerification.implementationOf(impostor), address(0));
        assertFalse(BERCVerification.isClonedFrom(impostor, address(runtime)));
    }

    function test_A45ByteImpostorWithAWrongEpilogueDoesNotVerify() public {
        address impostor = makeAddr("wrongEpilogue");
        // Final byte of the epilogue changed from 0xf3 (RETURN) to 0xff.
        vm.etch(
            impostor,
            abi.encodePacked(hex"363d3d373d3d3d363d73", address(runtime), hex"5af43d82803e903d91602b57fd5bff")
        );

        assertEq(impostor.code.length, 45);
        assertEq(BERCVerification.implementationOf(impostor), address(0));
        assertFalse(BERCVerification.isClonedFrom(impostor, address(runtime)));
    }

    /**
     * @dev A runtime with no code is not a runtime. A minimal proxy pointing at one `delegatecall`s into
     *      nothing, which succeeds and returns empty for every selector — so it would answer `balanceOf`
     *      with silence and pass a check that only compared addresses. Both halves of the pair have to
     *      have code for the comparison to mean anything.
     */
    function test_ACodelessRuntimeVerifiesNothing() public {
        address eoaRuntime = makeAddr("eoaPretendingToBeARuntime");
        address proxyToNowhere = Clones.clone(eoaRuntime);

        assertEq(BERCVerification.implementationOf(proxyToNowhere), eoaRuntime, "it really is a well-formed clone");
        assertFalse(BERCVerification.isClonedFrom(proxyToNowhere, eoaRuntime), "and it must still fail verification");
    }

    /// @dev Otherwise every EOA and every ordinary contract would verify against a zero runtime.
    function test_ZeroRuntimeVerifiesNothing() public {
        assertFalse(BERCVerification.isClonedFrom(_deployViaFactory(), address(0)));
        assertFalse(BERCVerification.isClonedFrom(makeAddr("nobody"), address(0)));
    }

    // -----------------------------------------------------------------------------------------------
    // The footgun
    // -----------------------------------------------------------------------------------------------

    /**
     * @dev An uninitialised clone runs canonical code and has no sealed extension set, so discovery
     *      reverts. An integrator that treats a reverting `behaviorFlags()` as "this token has no
     *      extensions" would classify it as a plain ERC-20 — the exact misreading `docs/INTEGRATION.md`
     *      warns about. Verification passing is not permission to skip reading the flags.
     */
    function test_UninitialisedCloneVerifiesButAnswersNothing() public {
        address bare = Clones.clone(address(runtime));

        assertTrue(BERCVerification.isClonedFrom(bare, address(runtime)), "the code is canonical");

        vm.expectRevert(ERC20ExtensionCore.ERC20ExtensionSetNotSealed.selector);
        BERCRuntimeV1(bare).behaviorFlags();

        vm.expectRevert(ERC20ExtensionCore.ERC20ExtensionSetNotSealed.selector);
        BERCRuntimeV1(bare).extensions();
    }

    function _deployViaFactory() private returns (address) {
        return factory.deploy(
            BERCFactoryV1.TokenParams({
                name: "Verified",
                symbol: "VER",
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
    }
}
