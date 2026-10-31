// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// This imports Revert's REAL fork-backed fixture and exercises V4Vault + RevertHook.
// No production deployments, transactions, or test-only protocol replacements.
import {V4VaultHookTest} from "test/vault/V4VaultHook.t.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";
import {Constants} from "src/shared/Constants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract SentinelXRemintAtomicity is V4VaultHookTest {
    // When hook migration rejects a newly minted range because its exit trigger
    // is already satisfied, all old loan, debt, NFT and hook state must roll back.
    function testSX_FailedHookMigrationAtomicRollback() public {
        PoolKey memory key = _createHookedPool();
        uint256 oldId = _createPositionInHookedPoolForAutoRange(key);
        _setupCollateralizedPositionForAutoLeverage(oldId);

        RevertHookState.PositionConfig memory cfg = _manualRangeMigrationConfig();
        cfg.modeFlags = PositionModeFlags.MODE_AUTO_EXIT;
        cfg.autoCollectMode = RevertHookState.AutoCollectMode.NONE;
        cfg.autoLeverageTargetBps = 0;
        cfg.autoExitIsRelative = true;
        cfg.autoExitTickLower = 600;
        _setPositionConfigAtTarget(oldId, cfg);

        uint256 loanSharesBefore = vault.loans(oldId);
        uint256 totalSharesBefore = vault.debtSharesTotal();
        uint128 oldLiquidityBefore = positionManager.getPositionLiquidity(oldId);
        uint256 nextTokenIdBefore = positionManager.nextTokenId();
        (uint32 lowerBefore, uint32 upperBefore) = _getTriggerListSizes(key);
        (uint8 oldModeBefore,,,,,,,,,,,,) = revertHook.positionConfigs(oldId);

        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(key));
        int24 spacing = key.tickSpacing;
        int24 base = (currentTick / spacing) * spacing;
        bytes memory data = _manualRangeMoveCalldata(
            oldId, oldLiquidityBefore, base + 20 * spacing, base + 30 * spacing
        );

        vm.prank(WHALE_ACCOUNT);
        vm.expectRevert(Constants.InvalidConfig.selector);
        vault.transform(oldId, address(v4Utils), data);

        assertEq(vault.transformedTokenId(), 0, "transform mutex leaked");
        assertEq(vault.loans(oldId), loanSharesBefore, "old debt changed on revert");
        assertEq(vault.debtSharesTotal(), totalSharesBefore, "global debt changed on revert");
        assertEq(positionManager.nextTokenId(), nextTokenIdBefore, "mint was not rolled back");
        assertEq(positionManager.getPositionLiquidity(oldId), oldLiquidityBefore, "old liquidity changed");
        assertEq(vault.ownerOf(oldId), WHALE_ACCOUNT, "loan ownership changed");
        assertEq(IERC721(address(positionManager)).ownerOf(oldId), address(vault), "NFT escaped vault");
        (uint32 lowerAfter, uint32 upperAfter) = _getTriggerListSizes(key);
        assertEq(lowerAfter, lowerBefore, "lower triggers changed on revert");
        assertEq(upperAfter, upperBefore, "upper triggers changed on revert");
        (uint8 oldModeAfter,,,,,,,,,,,,) = revertHook.positionConfigs(oldId);
        assertEq(oldModeAfter, oldModeBefore, "hook config changed on revert");
    }

    // Move only half of collateral to a fresh NFT. The full debt moves once,
    // the old NFT remains a debt-free husk, and the owner and triggers persist.
    function testSX_PartialRemintDebtAndHookConservation() public {
        PoolKey memory key = _createHookedPool();
        uint256 oldId = _createPositionInHookedPool(key);
        _setupCollateralizedPositionForAutoLeverage(oldId);
        revertHook.setMinPositionValueNative(0);
        RevertHookState.PositionConfig memory cfg = _manualRangeMigrationConfig();
        _setPositionConfigAtTarget(oldId, cfg);

        uint256 sharesBefore = vault.loans(oldId);
        assertGt(sharesBefore, 0, "fixture has no debt");
        uint256 globalBefore = vault.debtSharesTotal();
        (uint32 lowerBefore, uint32 upperBefore) = _getTriggerListSizes(key);
        uint128 liquidity = positionManager.getPositionLiquidity(oldId);
        assertGt(liquidity, 1, "fixture lacks divisible liquidity");

        uint256 newId = _executeManualRangeMove(oldId, liquidity / 2);
        assertTrue(newId != oldId, "no replacement NFT");
        assertEq(vault.debtSharesTotal(), globalBefore, "global debt changed during remint");
        assertEq(vault.loans(oldId), 0, "old loan still carries debt");
        assertEq(vault.loans(newId), sharesBefore, "debt shares lost or multiplied");
        assertEq(vault.ownerOf(oldId), WHALE_ACCOUNT, "old husk ownership changed");
        assertEq(vault.ownerOf(newId), WHALE_ACCOUNT, "new ownership changed");
        assertGt(positionManager.getPositionLiquidity(oldId), 0, "partial husk lost liquidity");
        assertEq(IERC721(address(positionManager)).ownerOf(newId), address(vault), "new NFT not held");
        assertEq(vault.transformedTokenId(), 0, "transform mutex not cleared");
        (uint8 oldMode,,,,,,,,,,,,) = revertHook.positionConfigs(oldId);
        (uint8 newMode,,,,,,,,,,,,) = revertHook.positionConfigs(newId);
        assertEq(oldMode, PositionModeFlags.MODE_NONE, "old hook remained armed");
        assertEq(newMode, cfg.modeFlags, "hook config was not migrated");
        (uint32 lowerAfter, uint32 upperAfter) = _getTriggerListSizes(key);
        assertEq(lowerAfter, lowerBefore, "lower trigger count changed");
        assertEq(upperAfter, upperBefore, "upper trigger count changed");
    }

    // A registered vault address must not be able to invoke migration outside
    // an active transform and mutate hook config for an unrelated position.
    function testSX_HookCallbackOutsideTransformFailsClosed() public {
        PoolKey memory key = _createHookedPool();
        uint256 oldId = _createPositionInHookedPool(key);
        uint256 newId = _createPositionInHookedPool(key);
        (uint8 oldModeBefore,,,,,,,,,,,,) = revertHook.positionConfigs(oldId);
        (uint8 newModeBefore,,,,,,,,,,,,) = revertHook.positionConfigs(newId);
        vm.prank(address(vault));
        vm.expectRevert(Constants.Unauthorized.selector);
        revertHook.migrateVaultPosition(oldId, newId);
        (uint8 oldModeAfter,,,,,,,,,,,,) = revertHook.positionConfigs(oldId);
        (uint8 newModeAfter,,,,,,,,,,,,) = revertHook.positionConfigs(newId);
        assertEq(oldModeAfter, oldModeBefore, "old hook config mutated");
        assertEq(newModeAfter, newModeBefore, "new hook config mutated");
    }
}
