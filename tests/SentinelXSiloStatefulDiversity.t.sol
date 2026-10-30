// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SiloLittleHelper} from "silo-core/test/foundry/_common/SiloLittleHelper.sol";

/// @notice Additive, isolated research hypotheses on a pinned Silo revision.
/// @dev Local fixtures only. Passing properties are not proof of global safety.
/// @dev MintableToken fixture assets are test funding, not attacker profit.
contract SentinelXSiloStatefulDiversityTest is SiloLittleHelper, Test {
    address internal constant ATTACKER = address(0xBAD);
    address internal constant VICTIM = address(0xA11CE);
    address internal constant LENDER = address(0xBEEF);

    function setUp() public {
        _setUpLocalFixture();
    }

    /// @dev Fisher-Yates generates a seeded permutation of all five actions.
    ///      Steps 5-15 select fresh pseudorandom operations; unlike the old
    ///      (seed + i) % 5 cycle, the campaign is NOT limited to five rotations.
    function testFuzz_DiverseActionOrdersMaintainDebtAndVictimIsolation(uint96 seed) public {
        _deposit(20e18, ATTACKER);
        _deposit(20e18, VICTIM);
        _depositForBorrow(60e18, LENDER);
        token1.mint(ATTACKER, 30e18); // synthetic fixture funding

        uint256 victimShares = silo0.balanceOf(VICTIM);
        uint8[5] memory order;
        for (uint256 k; k < 5; ++k) order[k] = uint8(k);
        for (uint256 n = 5; n > 1; --n) {
            uint256 j = uint256(keccak256(abi.encode(seed, n))) % n;
            uint8 tmp = order[n - 1];
            order[n - 1] = order[j];
            order[j] = tmp;
        }

        uint256 attemptedMask;
        for (uint256 i; i < 16; ++i) {
            uint256 random = uint256(keccak256(abi.encode(seed, i, silo1.maxRepayShares(ATTACKER))));
            uint256 operation = i < 5 ? order[i] : random % 5;
            attemptedMask |= uint256(1) << operation;
            uint256 priorShares = silo1.maxRepayShares(ATTACKER);

            if (operation == 0) {
                // Authorized borrow by collateral owner.
                uint256 amount = 1e15 + (random % 1e17);
                uint256 walletBefore = token1.balanceOf(ATTACKER);
                vm.prank(ATTACKER);
                uint256 mintedDebtShares = silo1.borrow(amount, ATTACKER, ATTACKER);
                assertGt(mintedDebtShares, 0, "BORROW_DID_NOT_MINT_DEBT");
                assertEq(silo1.maxRepayShares(ATTACKER), priorShares + mintedDebtShares,
                    "BORROW_SHARE_ACCOUNTING_MISMATCH");
                assertEq(token1.balanceOf(ATTACKER), walletBefore + amount, "BORROW_ASSET_MISMATCH");
            } else if (operation == 1) {
                // Authorized partial repayment, if shares exist.
                if (priorShares != 0) {
                    uint256 shares = priorShares / 2;
                    if (shares == 0) shares = priorShares;
                    uint256 expected = silo1.previewRepayShares(shares);
                    uint256 walletBefore = token1.balanceOf(ATTACKER);
                    assertGe(walletBefore, expected, "FIXTURE_REPAY_FUNDS_MISSING");
                    vm.prank(ATTACKER);
                    token1.approve(address(silo1), expected);
                    vm.prank(ATTACKER);
                    uint256 paid = silo1.repayShares(shares, ATTACKER);
                    assertEq(paid, expected, "REPAY_ASSET_COST_MISMATCH");
                    assertEq(token1.balanceOf(ATTACKER), walletBefore - paid, "UNPAID_DEBT_REDUCTION");
                    assertEq(silo1.maxRepayShares(ATTACKER), priorShares - shares,
                        "REPAY_SHARE_ACCOUNTING_MISMATCH");
                }
            } else if (operation == 2) {
                // Time/interest accrual must not mint new borrower debt shares.
                vm.warp(block.timestamp + (1 + (random % 24)) * 1 hours);
                silo1.accrueInterest();
                assertEq(silo1.maxRepayShares(ATTACKER), priorShares,
                    "INTEREST_UNEXPECTED_SHARE_MUTATION");
            } else if (operation == 3) {
                // Untrusted principal must not borrow against victim's collateral.
                uint256 attackerAssetsBefore = token1.balanceOf(ATTACKER);
                uint256 victimDebtBefore = silo1.maxRepayShares(VICTIM);
                vm.prank(ATTACKER);
                (bool allowed,) = address(silo1).call(abi.encodeWithSignature(
                    "borrow(uint256,address,address)", 1e15 + (random % 1e17), ATTACKER, VICTIM
                ));
                assertFalse(allowed, "UNAUTHORIZED_VICTIM_BORROW_SUCCEEDED");
                assertEq(silo1.maxRepayShares(VICTIM), victimDebtBefore,
                    "UNAUTHORIZED_VICTIM_DEBT_MUTATION");
                assertEq(token1.balanceOf(ATTACKER), attackerAssetsBefore,
                    "UNAUTHORIZED_BORROW_ASSET_PAYOUT");
            } else {
                // Untrusted principal must not withdraw victim's collateral.
                uint256 attackerCollateralBefore = silo0.balanceOf(ATTACKER);
                vm.prank(ATTACKER);
                (bool allowed,) = address(silo0).call(abi.encodeWithSignature(
                    "withdraw(uint256,address,address)", 1e15 + (random % 1e17), ATTACKER, VICTIM
                ));
                assertFalse(allowed, "UNAUTHORIZED_VICTIM_WITHDRAW_SUCCEEDED");
                assertEq(silo0.balanceOf(ATTACKER), attackerCollateralBefore,
                    "UNAUTHORIZED_COLLATERAL_CREDIT");
            }
            // Common postconditions after EVERY step, not only at final state.
            assertEq(silo0.balanceOf(VICTIM), victimShares, "VICTIM_COLLATERAL_STOLEN");
            assertEq(silo1.maxRepayShares(VICTIM), 0, "VICTIM_DEBT_CREATED");
            assertTrue(silo0.isSolvent(ATTACKER), "BORROWER_INSOLVENT");
        }
        assertEq(attemptedMask, 31, "ACTION_FAMILY_NOT_EXERCISED");
    }

    /// @dev Variation in unauthorized request amount and interest-accrual state.
    ///      Failed calls must not mutate any protected balance.
    function testFuzz_DeniedCrossIdentityCallsAreAtomic(uint96 seed) public {
        _deposit(20e18, VICTIM);
        _deposit(20e18, ATTACKER);
        _depositForBorrow(60e18, LENDER);
        uint256 victimCollateral = silo0.balanceOf(VICTIM);
        uint256 attackerCollateral = silo0.balanceOf(ATTACKER);
        uint256 victimDebt = silo1.maxRepayShares(VICTIM);
        uint256 attackerDebt = silo1.maxRepayShares(ATTACKER);
        uint256 attackerAssets = token1.balanceOf(ATTACKER);
        for (uint256 i; i < 4; ++i) {
            uint256 amount = 1e15 + (uint256(keccak256(abi.encode(seed, i))) % 1e17);
            vm.warp(block.timestamp + 1 hours);
            silo1.accrueInterest();
            vm.prank(ATTACKER);
            (bool borrowed,) = address(silo1).call(abi.encodeWithSignature(
                "borrow(uint256,address,address)", amount, ATTACKER, VICTIM
            ));
            vm.prank(ATTACKER);
            (bool withdrew,) = address(silo0).call(abi.encodeWithSignature(
                "withdraw(uint256,address,address)", amount, ATTACKER, VICTIM
            ));
            assertFalse(borrowed, "CROSS_IDENTITY_BORROW_ALLOWED");
            assertFalse(withdrew, "CROSS_IDENTITY_WITHDRAW_ALLOWED");
            assertEq(silo0.balanceOf(VICTIM), victimCollateral, "VICTIM_COLLATERAL_CHANGED");
            assertEq(silo0.balanceOf(ATTACKER), attackerCollateral, "ATTACKER_COLLATERAL_CHANGED");
            assertEq(silo1.maxRepayShares(VICTIM), victimDebt, "VICTIM_DEBT_CHANGED");
            assertEq(silo1.maxRepayShares(ATTACKER), attackerDebt, "ATTACKER_DEBT_CHANGED");
            assertEq(token1.balanceOf(ATTACKER), attackerAssets, "ATTACKER_ASSET_BALANCE_CHANGED");
        }
    }
}
