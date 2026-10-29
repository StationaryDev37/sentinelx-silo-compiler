// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin5/token/ERC20/IERC20.sol";
import {SiloLittleHelper} from "silo-core/test/foundry/_common/SiloLittleHelper.sol";
import {ISilo} from "silo-core/contracts/interfaces/ISilo.sol";
import {IERC3156FlashBorrower} from "silo-core/contracts/interfaces/IERC3156FlashBorrower.sol";

/// @dev A local attacker actor; no authorization, no cheatcodes, no live-chain calls.
contract SentinelXFlashCallback is IERC3156FlashBorrower {
    ISilo public immutable lender;
    ISilo public immutable sibling;
    IERC20 public immutable loanToken;
    address public immutable victim;
    bool public victimWithdrawSucceeded;
    bool public unsecuredBorrowSucceeded;

    constructor(ISilo _lender, ISilo _sibling, IERC20 _loanToken, address _victim) {
        lender = _lender;
        sibling = _sibling;
        loanToken = _loanToken;
        victim = _victim;
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        require(msg.sender == address(lender) && token == address(loanToken), "INVALID_FLASH_CALLBACK");

        // Attempt A: steal shares of another account while its market is in a flash-loan callback.
        (victimWithdrawSucceeded,) = address(lender).call(
            abi.encodeWithSignature("withdraw(uint256,address,address)", uint256(1e15), address(this), victim)
        );

        // Attempt B: borrow from a different market with no collateral assigned to this contract.
        (unsecuredBorrowSucceeded,) = address(sibling).call(
            abi.encodeWithSignature("borrow(uint256,address,address)", uint256(1e15), address(this), address(this))
        );

        require(loanToken.approve(address(lender), amount + fee), "FLASH_REPAY_APPROVAL_FAILED");
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @notice Hypothesis-driven adversarial checks, running entirely in Foundry's isolated local EVM.
/// @dev A failed assertion is NOT proof of exploitability; inspect call traces and victim loss.
contract SentinelXSiloCoreAdversarialTest is SiloLittleHelper, Test {
    address internal constant VICTIM = address(0xA11CE);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant LENDER = address(0xBEEF);

    function setUp() public {
        _setUpLocalFixture();
    }

    function testFuzz_UnapprovedBorrowCannotUseVictimCollateral(uint96 seed) public {
        uint256 amount = bound(uint256(seed), 1e15, 1e18);
        _deposit(20e18, VICTIM);
        _depositForBorrow(30e18, LENDER);

        // Ensure this checks authorization, not a lack of victim borrowing capacity.
        assertGe(silo1.maxBorrow(VICTIM), amount, "FIXTURE_VICTIM_BORROW_CAPACITY_TOO_LOW");
        uint256 beforeLiquidity = token1.balanceOf(address(silo1));
        uint256 beforeVictimShares = silo0.balanceOf(VICTIM);

        vm.prank(ATTACKER);
        (bool accepted,) = address(silo1).call(
            abi.encodeWithSignature("borrow(uint256,address,address)", amount, ATTACKER, VICTIM)
        );

        assertFalse(accepted, "POTENTIAL_AUTHZ_BYPASS_BORROW_ON_VICTIM");
        assertEq(silo1.maxRepayShares(VICTIM), 0, "VICTIM_ASSIGNED_UNAUTHORIZED_DEBT");
        assertEq(token1.balanceOf(ATTACKER), 0, "ATTACKER_RECEIVED_BORROWED_ASSETS");
        assertEq(token1.balanceOf(address(silo1)), beforeLiquidity, "LENDER_LIQUIDITY_CHANGED");
        assertEq(silo0.balanceOf(VICTIM), beforeVictimShares, "VICTIM_COLLATERAL_CHANGED");
    }

    function testFuzz_InterestPartialThenFullRepaymentBurnsAllDebt(uint96 seed, uint16 daysSeed) public {
        uint256 borrowAmount = bound(uint256(seed), 1e15, 3e18);
        uint256 elapsedDays = bound(uint256(daysSeed), 1, 30);
        _deposit(20e18, ATTACKER);
        _depositForBorrow(30e18, LENDER);
        uint256 originalDebtShares = _borrow(borrowAmount, ATTACKER);
        assertGt(originalDebtShares, 0, "FIXTURE_BORROW_DID_NOT_MINT_DEBT");

        vm.warp(block.timestamp + elapsedDays * 1 days);
        uint256 beforeDebtShares = silo1.maxRepayShares(ATTACKER);
        assertEq(beforeDebtShares, originalDebtShares, "DEBT_SHARES_CHANGED_WITHOUT_REPAYMENT");
        uint256 firstShares = beforeDebtShares / 2;
        assertGt(firstShares, 0, "FIXTURE_INSUFFICIENT_DEBT_SHARES");

        // Local fixture mints repayment tokens explicitly. This is NOT attacker profit.
        uint256 firstAssets = silo1.previewRepayShares(firstShares);
        _repayShares(firstAssets, firstShares, ATTACKER);
        uint256 remainingShares = silo1.maxRepayShares(ATTACKER);
        assertEq(remainingShares, beforeDebtShares - firstShares, "DEBT_SHARES_ACCOUNTING_DRIFT");

        uint256 finalAssets = silo1.previewRepayShares(remainingShares);
        _repayShares(finalAssets, remainingShares, ATTACKER);
        assertEq(silo1.maxRepayShares(ATTACKER), 0, "DEBT_NOT_BURNED_ON_FULL_REPAYMENT");
    }

    function testFuzz_FlashCallbackCannotDrainVictimOrBorrowWithoutCollateral(uint96 seed) public {
        uint256 flashAmount = bound(uint256(seed), 1e15, 3e18);
        _deposit(30e18, VICTIM);
        _depositForBorrow(30e18, LENDER);

        SentinelXFlashCallback receiver = new SentinelXFlashCallback(
            silo0, silo1, IERC20(address(token0)), VICTIM
        );
        uint256 fee = silo0.flashFee(address(token0), flashAmount);
        // Local test funds only the legitimate fee; loan principal arrives from the lender.
        token0.mint(address(receiver), fee);
        uint256 beforeLiquidity = token0.balanceOf(address(silo0));
        uint256 beforeVictimShares = silo0.balanceOf(VICTIM);

        silo0.flashLoan(IERC3156FlashBorrower(address(receiver)), address(token0), flashAmount, "");

        assertFalse(receiver.victimWithdrawSucceeded(), "POTENTIAL_FLASH_CALLBACK_VICTIM_DRAIN");
        assertFalse(receiver.unsecuredBorrowSucceeded(), "POTENTIAL_CROSS_MARKET_FREE_BORROW");
        assertEq(silo0.balanceOf(VICTIM), beforeVictimShares, "VICTIM_SHARES_CHANGED");
        assertEq(silo1.maxRepayShares(address(receiver)), 0, "UNBACKED_DEBT_CREATED");
        assertEq(token1.balanceOf(address(receiver)), 0, "UNBACKED_ASSETS_SENT_TO_ATTACKER");
        assertEq(token0.balanceOf(address(silo0)), beforeLiquidity + fee, "FLASH_LOAN_FUNDS_NOT_REPAID");
    }
}
