// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Test} from "forge-std/Test.sol";

import {BERCVerification} from "../../src/libraries/BERCVerification.sol";
import {ExtensionIds} from "../../src/libraries/ExtensionIds.sol";
import {BERCFactoryV1} from "../../src/runtime/BERCFactoryV1.sol";
import {BERCRuntimeV1} from "../../src/runtime/BERCRuntimeV1.sol";

contract VerificationTest is Test {
    BERCRuntimeV1 internal runtime;
    BERCFactoryV1 internal factory;
    address internal token;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");

    function setUp() public {
        runtime = new BERCRuntimeV1();
        factory = new BERCFactoryV1(address(runtime));

        BERCFactoryV1.TokenParams memory params;
        params.name = "Canonical";
        params.symbol = "CAN";
        params.admin = admin;
        params.extensionIds = new bytes4[](1);
        params.extensionIds[0] = ExtensionIds.TRANSFER_RESTRICTION;

        token = factory.deploy(params);
    }

    function test_ImplementationOfAClone() public view {
        assertEq(BERCVerification.implementationOf(token), address(runtime));
    }

    function test_AFactoryTokenVerifies() public view {
        assertTrue(BERCVerification.isClonedFrom(token, address(runtime)));
    }

    function test_ACloneMadeWithoutTheFactoryVerifiesJustTheSame() public {
        // The claim is about the code, not about provenance.
        address bare = Clones.clone(address(runtime));

        assertTrue(BERCVerification.isClonedFrom(bare, address(runtime)));
    }

    function test_AnEoaDoesNotVerify() public view {
        assertEq(BERCVerification.implementationOf(alice), address(0));
        assertFalse(BERCVerification.isClonedFrom(alice, address(runtime)));
    }

    function test_AnOrdinaryContractDoesNotVerify() public view {
        assertEq(BERCVerification.implementationOf(address(factory)), address(0));
        assertFalse(BERCVerification.isClonedFrom(address(factory), address(runtime)));
    }

    function test_TheRuntimeItselfIsNotAToken() public view {
        assertFalse(BERCVerification.isClonedFrom(address(runtime), address(runtime)));
    }

    function test_ACloneOfADifferentRuntimeDoesNotVerify() public {
        BERCRuntimeV1 other = new BERCRuntimeV1();

        assertFalse(BERCVerification.isClonedFrom(token, address(other)));
        assertTrue(BERCVerification.isClonedFrom(Clones.clone(address(other)), address(other)));
    }

    function test_AZeroRuntimeVerifiesNothing() public view {
        // Without the code-length check on `runtime`, every EOA would pass this.
        assertFalse(BERCVerification.isClonedFrom(alice, address(0)));
        assertFalse(BERCVerification.isClonedFrom(token, address(0)));
    }

    function test_ACodelessRuntimeVerifiesNothingEither() public {
        address empty = makeAddr("noCodeHere");

        // A minimal proxy pointing at nothing succeeds and returns empty for every selector, so it would
        // pass a naive check while behaving like no token at all.
        address decoy = Clones.clone(empty);
        assertFalse(BERCVerification.isClonedFrom(decoy, empty));
    }

    function test_AContractOfTheRightLengthButTheWrongBytesDoesNotVerify() public {
        address impostor = makeAddr("impostor");
        bytes memory fortyFive = new bytes(BERCVerification.MINIMAL_PROXY_CODE_LENGTH);
        vm.etch(impostor, fortyFive);

        assertEq(BERCVerification.implementationOf(impostor), address(0));
    }

    function test_TheEpilogueIsCheckedAndNotJustThePrologue() public {
        address impostor = makeAddr("impostorTwo");
        bytes memory code = new bytes(BERCVerification.MINIMAL_PROXY_CODE_LENGTH);

        // Correct 10-byte prologue, then the runtime address, then rubbish where the epilogue belongs.
        bytes memory prologue = hex"363d3d373d3d3d363d73";
        for (uint256 i = 0; i < prologue.length; ++i) {
            code[i] = prologue[i];
        }
        bytes20 target = bytes20(address(runtime));
        for (uint256 i = 0; i < 20; ++i) {
            code[10 + i] = target[i];
        }
        vm.etch(impostor, code);

        assertEq(BERCVerification.implementationOf(impostor), address(0));
    }

    function test_VerificationSaysNothingAboutConfiguration() public {
        // A verified token can still be paused. Verification is about identity, not about liking the rules.
        vm.prank(admin);
        BERCRuntimeV1(token).setTransfersPaused(true);

        assertTrue(BERCVerification.isClonedFrom(token, address(runtime)));
        assertTrue(BERCRuntimeV1(token).transfersPaused());
    }
}
