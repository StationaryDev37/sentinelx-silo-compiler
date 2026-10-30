// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SiloLittleHelper} from "silo-core/test/foundry/_common/SiloLittleHelper.sol";
import {ISilo} from "silo-core/contracts/interfaces/ISilo.sol";

/// @notice Separate multi-operation adversarial campaign against the pinned Silo core.
/// @dev TEST RESULTS ARE NOT FINANCIAL EXPLOITS. Review traces and independent controls.
/// @dev The MintableToken fixture is deliberately artificial: no financial profit claim is valid here.
contract SentinelXSiloStatefulResearchTest is SiloLittleHelper, Test {
    address internal constant ATTACKER = address(0xBAD);
    address internal constant VICTIM = address(0xA11CE);
    address internal constant LENDER = address(0xBEEF);

    function setUp() public {
        _setUpLocalFixture();
    }

    /// @dev Every iteration rotates through all five operations twice.
    ///      The seed varies ordering and amount. The checks bind state transitions,
    ///      not the success/failure of a scanner pattern.
    function testFuzz_StatefulDebtAndAccessControls(uint96 seed) public {
        _deposit(20e18, ATTACKER);
        _deposit(20e18, VICTIM);
        _depositForBorrow(60e18, LENDER);
        token1.mint(ATTACKER, 30e18); // EXPLICIT test funding. Never count this as attacker profit.
        uint256 victimShares = silo0.balanceOf(VICTIM);

        for (uint256 i; i < 10; ++i) {
            uint256 operation = (uint256(seed) + i) % 5;
            uint256 previousDebt = silo1.maxRepayShares(ATTACKER);

            if (operation == 0) {
                uint256 amount = 1e15 + (uint256(keccak256(abi.encode(seed, i))) % 1e17);
                uint256 walletBefore = token1.balanceOf(ATTACKER);
                vm.prank(ATTACKER);
                uint256 createdShares = silo1.borrow(amount, ATTACKER, ATTACKER);
                assertGt(createdShares, 0, "BORROW_DID_NOT_CREATE_DEBT_SHARES");
                assertEq(silo1.maxRepayShares(ATTACKER), previousDebt + createdShares,
                    "DEBT_SHARE_CREATION_MISMATCH");
                assertEq(token1.balanceOf(ATTACKER), walletBefore + amount, "BORROW_PAYOUT_MISMATCH");
            } else if (operation == 1) {
                if (previousDebt != 0) {
                    uint256 repayShares = previousDebt / 2;
                    if (repayShares == 0) repayShares = previousDebt;
                    uint256 expectedCost = silo1.previewRepayShares(repayShares);
                    uint256 walletBefore = token1.balanceOf(ATTACKER);
                    assertGe(walletBefore, expectedCost, "FIXTURE_PREPAID_FUNDS_INSUFFICIENT");
                    vm.prank(ATTACKER);
                    token1.approve(address(silo1), expectedCost);
                    vm.prank(ATTACKER);
                    uint256 paid = silo1.repayShares(repayShares, ATTACKER);
                    assertEq(paid, expectedCost, "REPAY_COST_MISMATCH");
                    assertEq(token1.balanceOf(ATTACKER), walletBefore - paid,
                        "DEBT_BURNED_WITHOUT_ASSET_PAYMENT");
                    assertEq(silo1.maxRepayShares(ATTACKER), previousDebt - repayShares,
                        "REPAY_DEBT_SHARE_MISMATCH");
                }
            } else if (operation == 2) {
                vm.warp(block.timestamp + 1 hours);
                silo1.accrueInterest();
                assertEq(silo1.maxRepayShares(ATTACKER), previousDebt,
                    "INTEREST_CHANGED_SHARE_COUNT_WITHOUT_BORROW_OR_REPAY");
            } else if (operation == 3) {
                uint256 victimDebtBefore = silo1.maxRepayShares(VICTIM);
                uint256 attackerBalanceBefore = token1.balanceOf(ATTACKER);
                vm.prank(ATTACKER);
                (bool approved,) = address(silo1).call(abi.encodeWithSignature(
                    "borrow(uint256,address,address)", uint256(1e15), ATTACKER, VICTIM
                ));
                assertFalse(approved, "UNAUTHORIZED_BORROW_USING_VICTIM_COLLATERAL");
                assertEq(silo1.maxRepayShares(VICTIM), victimDebtBefore, "UNAUTHORIZED_VICTIM_DEBT");
                assertEq(token1.balanceOf(ATTACKER), attackerBalanceBefore,
                    "UNAUTHORIZED_ASSET_PAYOUT");
            } else {
                vm.prank(ATTACKER);
                (bool approved,) = address(silo0).call(abi.encodeWithSignature(
                    "withdraw(uint256,address,address)", uint256(1e15), ATTACKER, VICTIM
                ));
                assertFalse(approved, "UNAUTHORIZED_WITHDRAW_OF_VICTIM_COLLATERAL");
            }
            assertEq(silo0.balanceOf(VICTIM), victimShares, "VICTIM_SHARES_CHANGED_BY_ATTACKER");
            assertEq(silo1.maxRepayShares(VICTIM), 0, "VICTIM_GIVEN_DEBT");
            assertTrue(silo0.isSolvent(ATTACKER), "ATTESTED_BORROWER_INSOLVENT");
        }
    }

    /// @notice Can a leveraged actor shift collateral shares while retaining the debt?
    /// A successful transfer is allowed only while the remaining account is solvent.
    function testFuzz_TransferCannotLeaveBorrowerInsolvent(uint96 seed) public {
        _deposit(20e18, ATTACKER);
        _depositForBorrow(40e18, LENDER);
        _borrow(5e18, ATTACKER);
        uint256 beforeDebt = silo1.maxRepayShares(ATTACKER);
        uint256 initialShares = silo0.balanceOf(ATTACKER);
        uint256 moveShares = bound(uint256(seed), 1, initialShares);
        vm.prank(ATTACKER);
        (bool transferred,) = address(silo0).call(abi.encodeWithSignature(
            "transfer(address,uint256)", VICTIM, moveShares
        ));
        assertEq(silo1.maxRepayShares(ATTACKER), beforeDebt, "DEBT_CHANGED_WITH_SHARE_TRANSFER");
        if (transferred) {
            assertEq(silo0.balanceOf(ATTACKER), initialShares - moveShares,
                "COLLATERAL_TRANSFER_INCORRECT");
            assertEq(silo0.balanceOf(VICTIM), moveShares, "VICITM_SHARES_MISMATCH");
            assertTrue(silo0.isSolvent(ATTACKER), "INSOLVENT_TRANSFER_ACCEPTED");
        } else {
            assertEq(silo0.balanceOf(ATTACKER), initialShares, "FAILED_TRANSFER_MUTATED_COLLATERAL");
            assertEq(silo0.balanceOf(VICTIM), 0, "FAILED_TRANSFER_CREDITED_VICTIM");
        }
    }

    /// @notice A third party can pay someone else's debt, but must not acquire their collateral.
    function testFuzz_ThirdPartyDebtPayoffCannotCaptureCollateral(uint96 seed) public {
        uint128 amount = uint128(bound(uint256(seed), 1e15, 2e18));
        uint256 debtShares = _createDebt(amount, VICTIM);
        uint256 collateralBefore = silo0.balanceOf(VICTIM);
        vm.warp(block.timestamp + 1 hours);
        uint256 cost = silo1.previewRepayShares(debtShares);
        token1.mint(ATTACKER, cost); // EXPLICIT attacker-funded repayment, not profit.
        vm.prank(ATTACKER);
        token1.approve(address(silo1), cost);
        uint256 walletBefore = token1.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        uint256 paid = silo1.repayShares(debtShares, VICTIM);
        assertEq(paid, cost, "THIRD_PARTY_PAYMENT_COST_DRIFT");
        assertEq(token1.balanceOf(ATTACKER), walletBefore - paid,
            "DEBT_WIPED_WITHOUT_PAYMENT");
        assertEq(silo1.maxRepayShares(VICTIM), 0, "VICTIM_DEBT_NOT_CLEARED");
        assertEq(silo0.balanceOf(VICTIM), collateralBefore, "VICTIM_COLLATERAL_CAPTURED");
        assertEq(silo0.balanceOf(ATTACKER), 0, "ATTACKER_RECEIVED_UNEARNED_SHARES");
    }
}
