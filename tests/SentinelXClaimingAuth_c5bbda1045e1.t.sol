// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "openzeppelin5/proxy/Clones.sol";
import {IERC4626} from "openzeppelin5/interfaces/IERC4626.sol";
import {VaultIncentivesModule} from "silo-vaults/contracts/incentives/VaultIncentivesModule.sol";
import {ISiloVault, ISiloVaultBase} from "silo-vaults/contracts/interfaces/ISiloVault.sol";
import {IIncentivesClaimingLogic} from "silo-vaults/contracts/interfaces/IIncentivesClaimingLogic.sol";
import {IIncentivesClaimingLogicFactory} from "silo-vaults/contracts/interfaces/IIncentivesClaimingLogicFactory.sol";
import {IVaultIncentivesModule} from "silo-vaults/contracts/interfaces/IVaultIncentivesModule.sol";
import {ErrorsLib} from "silo-vaults/contracts/libraries/ErrorsLib.sol";

/// @notice Local negative/positive authorization controls for pinned public Silo source.
/// A passing test does NOT assert exploitability or rule out all bypass paths.
contract SentinelXClaimingAuthTest is Test {
    uint256 internal constant LOCK = 1 days;
    address internal constant OWNER = address(0xA11CE);
    address internal constant GUARDIAN = address(0xB01);
    address internal constant CURATOR = address(0xC0A7);
    address internal constant OUTSIDER = address(0xBAD);
    ISiloVault internal constant VAULT = ISiloVault(address(0xB00B));
    IERC4626 internal constant MARKET = IERC4626(address(0xAA01));
    IIncentivesClaimingLogic internal constant LOGIC = IIncentivesClaimingLogic(address(0xAC01));
    IIncentivesClaimingLogicFactory internal constant FACTORY = IIncentivesClaimingLogicFactory(address(0xFA01));

    VaultIncentivesModule internal module;

    function setUp() public {
        module = VaultIncentivesModule(Clones.clone(address(new VaultIncentivesModule())));
        module.__VaultIncentivesModule_init(
            VAULT, address(0), new IIncentivesClaimingLogic[](0),
            new IERC4626[](0), new IIncentivesClaimingLogicFactory[](0)
        );
        vm.mockCall(address(VAULT), abi.encodeWithSelector(ISiloVaultBase.timelock.selector), abi.encode(LOCK));
        vm.mockCall(address(VAULT), abi.encodeWithSelector(ISiloVaultBase.guardian.selector), abi.encode(GUARDIAN));
        vm.mockCall(address(VAULT), abi.encodeWithSelector(ISiloVaultBase.curator.selector), abi.encode(CURATOR));
        vm.mockCall(address(VAULT), abi.encodeWithSignature("owner()"), abi.encode(OWNER));
    }

    function testUnprivilegedCannotSubmitClaimingLogic() public {
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        vm.prank(OUTSIDER);
        module.submitIncentivesClaimingLogic(MARKET, LOGIC);
        assertEq(module.pendingClaimingLogics(MARKET, LOGIC), 0);
        assertEq(module.getAllIncentivesClaimingLogics().length, 0);
    }

    function testCuratorCannotSubmitUntrustedLogic() public {
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        vm.prank(CURATOR);
        module.submitIncentivesClaimingLogic(MARKET, LOGIC);
        assertEq(module.pendingClaimingLogics(MARKET, LOGIC), 0);
    }

    function testUnsubmittedLogicCannotBeAccepted() public {
        vm.warp(block.timestamp + LOCK * 2);
        vm.expectRevert(IVaultIncentivesModule.CantAcceptLogic.selector);
        vm.prank(OUTSIDER);
        module.acceptIncentivesClaimingLogic(MARKET, LOGIC);
        assertEq(module.getAllIncentivesClaimingLogics().length, 0);
    }

    function testOwnerSubmissionEarlyAcceptDeniedMatureAcceptAllowed() public {
        vm.prank(OWNER);
        module.submitIncentivesClaimingLogic(MARKET, LOGIC);
        uint256 validAt = module.pendingClaimingLogics(MARKET, LOGIC);
        assertEq(validAt, block.timestamp + LOCK);

        vm.warp(validAt - 1);
        vm.expectRevert(IVaultIncentivesModule.CantAcceptLogic.selector);
        vm.prank(OUTSIDER);
        module.acceptIncentivesClaimingLogic(MARKET, LOGIC);
        assertEq(module.getAllIncentivesClaimingLogics().length, 0);

        vm.warp(validAt);
        vm.prank(OUTSIDER); // public acceptance after authorized proposal/timelock is by design
        module.acceptIncentivesClaimingLogic(MARKET, LOGIC);
        address[] memory logics = module.getAllIncentivesClaimingLogics();
        assertEq(logics.length, 1);
        assertEq(logics[0], address(LOGIC));
        assertEq(module.pendingClaimingLogics(MARKET, LOGIC), 0);
    }

    function testGuardianRevocationInvalidatesLaterAccept() public {
        vm.prank(OWNER);
        module.submitIncentivesClaimingLogic(MARKET, LOGIC);
        vm.prank(GUARDIAN);
        module.revokePendingClaimingLogic(MARKET, LOGIC);
        vm.warp(block.timestamp + LOCK * 2);
        vm.expectRevert(IVaultIncentivesModule.CantAcceptLogic.selector);
        vm.prank(OUTSIDER);
        module.acceptIncentivesClaimingLogic(MARKET, LOGIC);
        assertEq(module.getAllIncentivesClaimingLogics().length, 0);
    }

    function testUnprivilegedCannotTrustFactory() public {
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        vm.prank(OUTSIDER);
        module.submitTrustedFactory(FACTORY);
        assertFalse(module.isTrustedFactory(FACTORY));
    }

    function testTrustedFactorySubmissionHonorsTimelock() public {
        vm.prank(OWNER);
        module.submitTrustedFactory(FACTORY);
        vm.expectRevert(IVaultIncentivesModule.CantAcceptFactory.selector);
        vm.prank(OUTSIDER);
        module.acceptTrustedFactory(FACTORY);
        assertFalse(module.isTrustedFactory(FACTORY));
        vm.warp(block.timestamp + LOCK + 1);
        vm.prank(OUTSIDER);
        module.acceptTrustedFactory(FACTORY);
        assertTrue(module.isTrustedFactory(FACTORY));
    }

    function testCuratorOnlyForFactoryRecognizedLogic() public {
        vm.prank(OWNER);
        module.submitTrustedFactory(FACTORY);
        vm.warp(block.timestamp + LOCK + 1);
        module.acceptTrustedFactory(FACTORY);
        vm.mockCall(
            address(FACTORY),
            abi.encodeWithSelector(IIncentivesClaimingLogicFactory.createdInFactory.selector, LOGIC),
            abi.encode(true)
        );
        vm.expectRevert(ErrorsLib.NotCuratorRole.selector);
        vm.prank(OUTSIDER);
        module.submitIncentivesClaimingLogic(MARKET, LOGIC);
        assertEq(module.pendingClaimingLogics(MARKET, LOGIC), 0);

        vm.prank(CURATOR);
        module.submitIncentivesClaimingLogic(MARKET, LOGIC);
        assertEq(module.pendingClaimingLogics(MARKET, LOGIC), block.timestamp);
        vm.prank(OUTSIDER);
        module.acceptIncentivesClaimingLogic(MARKET, LOGIC);
        assertEq(module.getAllIncentivesClaimingLogics().length, 1);
    }
}
