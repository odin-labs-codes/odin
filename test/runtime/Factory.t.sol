// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {BERCVerification} from "../../src/libraries/BERCVerification.sol";
import {ExtensionIds} from "../../src/libraries/ExtensionIds.sol";
import {BERCFactoryV1} from "../../src/runtime/BERCFactoryV1.sol";
import {BERCRuntimeV1} from "../../src/runtime/BERCRuntimeV1.sol";

contract FactoryTest is Test {
    BERCRuntimeV1 internal runtime;
    BERCFactoryV1 internal factory;

    address internal admin = makeAddr("admin");
    address internal feeAuthority = makeAddr("feeAuthority");
    address internal restrictionAuthority = makeAddr("restrictionAuthority");
    address internal vault = makeAddr("feeVault");
    address internal alice = makeAddr("alice");

    function setUp() public {
        runtime = new BERCRuntimeV1();
        factory = new BERCFactoryV1(address(runtime));
    }

    function _params() private view returns (BERCFactoryV1.TokenParams memory params) {
        params.name = "Canonical";
        params.symbol = "CAN";
        params.admin = admin;
        params.extensionIds = new bytes4[](1);
        params.extensionIds[0] = ExtensionIds.TRANSFER_RESTRICTION;
    }

    function _feeParams() private view returns (BERCFactoryV1.TokenParams memory params) {
        params = _params();
        params.extensionIds = new bytes4[](2);
        params.extensionIds[0] = ExtensionIds.TRANSFER_RESTRICTION;
        params.extensionIds[1] = ExtensionIds.TRANSFER_FEE;
        params.feeVault = vault;
        params.feeBasisPoints = 100;
        params.maximumFee = 5e18;
    }

    function test_TheDeployedTokenVerifiesAgainstTheRuntime() public {
        address token = factory.deploy(_params());

        assertTrue(BERCVerification.isClonedFrom(token, address(runtime)));
        assertEq(factory.RUNTIME(), address(runtime));
    }

    function test_TheIndexGrowsInDeploymentOrder() public {
        address first = factory.deploy(_params());
        address second = factory.deploy(_params());

        assertEq(factory.tokenCount(), 2);
        assertEq(factory.tokenAt(0), first);
        assertEq(factory.tokenAt(1), second);
        assertTrue(factory.isDeployedToken(first));
    }

    function test_ATokenTheFactoryDidNotMakeIsNotIndexed() public view {
        assertFalse(factory.isDeployedToken(alice));
    }

    function test_TheTokenIsUsableStraightAway() public {
        BERCRuntimeV1 token = BERCRuntimeV1(factory.deploy(_params()));

        vm.prank(admin);
        token.mint(alice, 10e18);

        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.name(), "Canonical");
    }

    function test_TheFeeConfigurationIsAppliedAtDeployment() public {
        BERCRuntimeV1 token = BERCRuntimeV1(factory.deploy(_feeParams()));

        assertEq(token.feeVault(), vault);
        assertEq(token.feeBasisPoints(), 100);
        assertEq(token.maximumFee(), 5e18);
    }

    function test_TheVaultIsExemptWithoutAnExplicitEntry() public {
        BERCRuntimeV1 token = BERCRuntimeV1(factory.deploy(_feeParams()));

        assertTrue(token.isFeeExempt(vault));
    }

    function test_RolesLandOnTheirIntendedHolders() public {
        BERCFactoryV1.TokenParams memory params = _feeParams();
        params.authorities.fee = feeAuthority;
        params.authorities.restriction = restrictionAuthority;

        BERCRuntimeV1 token = BERCRuntimeV1(factory.deploy(params));

        assertTrue(token.hasRole(token.FEE_CONFIG_ROLE(), feeAuthority));
        assertTrue(token.hasRole(token.RESTRICTION_ROLE(), restrictionAuthority));
        assertFalse(token.hasRole(token.FEE_CONFIG_ROLE(), admin));
    }

    function test_UnsetAuthoritiesFallBackToTheAdmin() public {
        BERCRuntimeV1 token = BERCRuntimeV1(factory.deploy(_params()));

        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.hasRole(token.SUPPLY_ROLE(), admin));
        assertTrue(token.hasRole(token.METADATA_ROLE(), admin));
        assertTrue(token.hasRole(token.RESTRICTION_ROLE(), admin));
    }

    function test_TheFactoryKeepsNothingAfterwards() public {
        BERCRuntimeV1 token = BERCRuntimeV1(factory.deploy(_feeParams()));

        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(factory)));
        assertFalse(token.hasRole(token.FEE_CONFIG_ROLE(), address(factory)));
        assertFalse(token.hasRole(token.SUPPLY_ROLE(), address(factory)));
    }

    function test_TheNewAuthoritiesCanActImmediately() public {
        BERCFactoryV1.TokenParams memory params = _feeParams();
        params.authorities.fee = feeAuthority;

        BERCRuntimeV1 token = BERCRuntimeV1(factory.deploy(params));

        vm.prank(feeAuthority);
        token.setFeeConfig(250, 1e18);

        assertEq(token.feeBasisPoints(), 250);
    }

    function test_ADeterministicDeployLandsWhereItWasPredicted() public {
        bytes32 salt = keccak256("salt");
        address predicted = factory.predictDeterministicAddress(address(this), salt);

        address token = factory.deployDeterministic(_params(), salt);

        assertEq(token, predicted);
        assertTrue(factory.isDeployedToken(token));
    }

    function test_TheSaltIsMixedWithTheDeployer() public view {
        bytes32 salt = keccak256("salt");

        assertTrue(
            factory.predictDeterministicAddress(address(this), salt)
                != factory.predictDeterministicAddress(alice, salt)
        );
    }

    function test_TheEventCarriesTheSealedSet() public {
        BERCFactoryV1.TokenParams memory params = _params();

        vm.recordLogs();
        address token = factory.deploy(params);

        assertEq(BERCRuntimeV1(token).extensions()[0], params.extensionIds[0]);
    }

    function test_RevertWhen_TheRuntimeHasNoCode() public {
        vm.expectRevert(abi.encodeWithSelector(BERCFactoryV1.BERCInvalidRuntime.selector, alice));
        new BERCFactoryV1(alice);
    }
}
