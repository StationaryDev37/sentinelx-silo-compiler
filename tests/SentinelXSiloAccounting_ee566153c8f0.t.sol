// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IntegrationTest} from "silo-vaults/test/foundry/helpers/IntegrationTest.sol";
import {CAP} from "silo-vaults/test/foundry/helpers/BaseTest.sol";

/// @notice Multi-user accounting hypotheses against Silo's unchanged contracts.
/// @dev A pass is a negative result for the sequences tested, NOT a vulnerability proof.
contract SentinelXSiloAccountingTest is IntegrationTest {
    function setUp() public override {
        super.setUp();
        _setCap(allMarkets[0], CAP);
        _sortSupplyQueueIdleLast();
    }

    /// Attacker enters after a victim and exits; no positive extraction without yield.
    function testFuzz_AttackerEntersLastCannotExtractVictimAssets(
        uint96 victimSeed, uint96 attackerSeed
    ) public {
        uint256 victimIn = bound(uint256(victimSeed), 1e12, 1e21);
        uint256 attackerIn = bound(uint256(attackerSeed), 1e12, 1e21);

        vm.prank(SUPPLIER);
        vault.deposit(victimIn, ONBEHALF);
        uint256 victimShares = vault.balanceOf(ONBEHALF);

        vm.prank(BORROWER);
        uint256 attackerShares = vault.deposit(attackerIn, BORROWER);
        assertGt(attackerShares, 0);

        vm.prank(BORROWER);
        uint256 attackerOut = vault.redeem(attackerShares, BORROWER, BORROWER);

        assertLe(attackerOut, attackerIn, "ATTACK: later depositor extracted value");
        assertEq(vault.balanceOf(ONBEHALF), victimShares, "VICTIM_SHARES_MUTATED");
        assertEq(vault.balanceOf(BORROWER), 0, "ATTACKER_SHARES_NOT_BURNED");
    }

    /// Reverse entry order to expose share-price or order-dependent extraction.
    function testFuzz_AttackerEntersFirstCannotExtractVictimAssets(
        uint96 victimSeed, uint96 attackerSeed
    ) public {
        uint256 victimIn = bound(uint256(victimSeed), 1e12, 1e21);
        uint256 attackerIn = bound(uint256(attackerSeed), 1e12, 1e21);

        vm.prank(BORROWER);
        uint256 attackerShares = vault.deposit(attackerIn, BORROWER);

        vm.prank(SUPPLIER);
        vault.deposit(victimIn, ONBEHALF);
        uint256 victimShares = vault.balanceOf(ONBEHALF);

        vm.prank(BORROWER);
        uint256 attackerOut = vault.redeem(attackerShares, BORROWER, BORROWER);

        assertLe(attackerOut, attackerIn, "ATTACK: earlier depositor extracted value");
        assertEq(vault.balanceOf(ONBEHALF), victimShares, "VICTIM_SHARES_MUTATED");
        assertEq(vault.balanceOf(BORROWER), 0, "ATTACKER_SHARES_NOT_BURNED");
    }

    /// Tests the accounting boundary across two different exit methods.
    function testFuzz_PartialWithdrawThenRedeemCannotIncreasePayout(uint96 seed) public {
        uint256 attackerIn = bound(uint256(seed), 1e12, 1e21);
        uint256 victimIn = 100e18;

        vm.prank(SUPPLIER);
        vault.deposit(victimIn, ONBEHALF);
        uint256 victimShares = vault.balanceOf(ONBEHALF);

        vm.prank(BORROWER);
        vault.deposit(attackerIn, BORROWER);

        uint256 partial = attackerIn / 3;
        vm.prank(BORROWER);
        vault.withdraw(partial, BORROWER, BORROWER);

        uint256 sharesRemaining = vault.balanceOf(BORROWER);
        vm.prank(BORROWER);
        uint256 finalOut = vault.redeem(sharesRemaining, BORROWER, BORROWER);

        assertLe(partial + finalOut, attackerIn, "ATTACK: split exit created assets");
        assertEq(vault.balanceOf(ONBEHALF), victimShares, "VICTIM_SHARES_MUTATED");
        assertEq(vault.balanceOf(BORROWER), 0, "ATTACKER_SHARES_NOT_BURNED");
    }
}
