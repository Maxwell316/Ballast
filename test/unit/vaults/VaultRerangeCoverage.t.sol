// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Position as PoolPosition} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookFixture} from "../../utils/HookFixture.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {IBallastErrors} from "../../../src/interfaces/IBallastErrors.sol";
import {IBallastEvents} from "../../../src/interfaces/IBallastEvents.sol";
import {CuratorRecord, PositionView, Range, VaultView} from "../../../src/types/Types.sol";

/// @notice Atomic re-range, the dust rule, commitment changes, and the coverage and breach flow (M4;
/// R-VLT-10, R-VLT-12, R-COV-1..4, INV-7).
/// @dev In a cold-oracle pool the anchor is the initial tick (0), so the band is `[-bandTicks, 0]` and a vault over
/// (-6000, 6000) with liquidity 1e19 has a committed depth of roughly 3.6e17 collateral.
/// @custom:requirement R-VLT-10 R-VLT-12 R-COV-1 R-COV-2 R-COV-3
/// @custom:invariant INV-7
contract VaultRerangeCoverageTest is HookFixture {
    using StateLibrary for IPoolManager;

    uint128 internal constant COVERED = 3e17; // below the roughly 3.97e17 the wide vault commits
    uint128 internal constant UNCOVERED = 5e17;

    function setUp() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
    }

    function _one(int24 lo, int24 hi) internal pure returns (Range[] memory r) {
        r = new Range[](1);
        r[0] = Range(lo, hi);
    }

    function _l(uint128 x) internal pure returns (uint128[] memory a) {
        a = new uint128[](1);
        a[0] = x;
    }

    function _vault(uint128 commitment) internal returns (uint256 v) {
        v = vaults.createVault(_one(-6000, 6000), commitment, 0);
        vaults.seed(v, _l(1e19), type(uint128).max, type(uint128).max, address(this));
    }

    function _poolLiq(uint256 v, uint256 slot, int24 lo, int24 hi) internal view returns (uint128) {
        bytes32 k =
            PoolPosition.calculatePositionKey(address(vaults), lo, hi, bytes32((v << 8) | slot));
        return IPoolManager(address(pm)).getPositionLiquidity(pid, k);
    }

    // ─── sanity of the fixture's depth ───

    function test_Fixture_WideVaultCommitsAboutFourTenthsOfACollateralUnit() public {
        uint256 v = _vault(0);
        uint256 d = lens.vaultDepth(v);
        assertGt(d, 3.9e17);
        assertLt(d, 4.0e17);
    }

    // ─── rerange ───

    function test_Rerange_MovesLiquidity_AndCreditsTheNetToIdle() public {
        uint256 v = _vault(COVERED);
        vm.warp(vm.getBlockTimestamp() + 60);
        vaults.rerange(v, _one(-3000, 3000), _l(8e18));
        assertEq(_poolLiq(v, 0, -6000, 6000), 0, "old position emptied");
        assertEq(_poolLiq(v, 0, -3000, 3000), 8e18, "new position funded");
        PositionView[] memory p = lens.positionsOf(v);
        assertEq(p.length, 1);
        assertEq(p[0].tickLower, -3000);
        assertEq(p[0].liquidity, 8e18);
        VaultView memory d = lens.vault(v);
        assertGt(d.idle0 + d.idle1, 0, "recovered tokens that the smaller position does not need are idle");
        assertEq(lens.vaultRecord(v).rerangeCount, 1);
        // Shares are untouched by a re-range (G-2).
        assertEq(d.totalShares, 1e18);
    }

    function test_Rerange_SameRangeSameLiquidity_DustRuleShrinksByMinimalLiquidity() public {
        uint256 v = _vault(COVERED);
        vaults.rerange(v, _one(-6000, 6000), _l(1e19));
        uint128 after_ = lens.positionsOf(v)[0].liquidity;
        assertLt(after_, 1e19, "rounding costs the vault a sliver, never the other way");
        assertGe(after_, 1e19 - 1e3, "the shrink is minimal (units of liquidity, not tokens)");
        assertEq(_poolLiq(v, 0, -6000, 6000), after_, "INV-2: recorded equals pool");
        VaultView memory d = lens.vault(v);
        assertLe(d.idle0, 2, "idle holds at most rounding dust");
        assertLe(d.idle1, 2);
    }

    function test_RevertWhen_Rerange_CoverageBelowCommitment() public {
        uint256 v = _vault(COVERED);
        vm.expectRevert(); // CoverageBelowCommitment(depth, commitment)
        vaults.rerange(v, _one(3000, 6000), _l(1e19)); // entirely above the band for a collateral-is-token0 vault
        // State unchanged after the revert (INV-7).
        assertEq(_poolLiq(v, 0, -6000, 6000), 1e19);
    }

    function test_RevertWhen_Rerange_InvalidCaller_Input_OrState() public {
        uint256 v = _vault(0);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.NotCurator.selector, address(0xBAD)));
        vaults.rerange(v, _one(-60, 60), _l(1e18));
        vm.expectRevert(IBallastErrors.InvalidLiquidities.selector);
        vaults.rerange(v, _one(-60, 60), new uint128[](2));
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.InvalidRange.selector, int24(-61), int24(60)));
        vaults.rerange(v, _one(-61, 60), _l(1e18));
        uint256 unseeded = vaults.createVault(_one(-60, 60), 0, 0);
        vm.expectRevert(IBallastErrors.VaultNotSeeded.selector);
        vaults.rerange(unseeded, _one(-60, 60), _l(1e18));
    }

    function test_Rerange_CanGrowLiquidity_WhenIdleCoversTheNet() public {
        uint256 v = _vault(COVERED);
        // First shrink: recovered tokens flow into idle.
        vaults.rerange(v, _one(-6000, 6000), _l(8e18));
        VaultView memory mid = lens.vault(v);
        assertGt(mid.idle0 + mid.idle1, 0);
        // Then grow a little: the net is paid from idle.
        vaults.rerange(v, _one(-6000, 6000), _l(8e18 + 1e17));
        assertEq(lens.positionsOf(v)[0].liquidity, 8e18 + 1e17);
    }

    /// @notice A shortfall that is not rounding dust reverts instead of silently shrinking the new position
    /// (ADR-049, ADR-055); the vault is left exactly as it was.
    function test_RevertWhen_Rerange_ShortfallIsNotDust() public {
        uint256 v = _vault(COVERED);
        VaultView memory before_ = lens.vault(v);
        vm.expectRevert(IBallastErrors.InsufficientIdle.selector);
        vaults.rerange(v, _one(-6000, 6000), _l(2e19));
        assertEq(lens.positionsOf(v)[0].liquidity, 1e19);
        assertEq(lens.vault(v).idle0, before_.idle0);
    }

    // ─── commitment ───

    function test_SetCommitment_IncreaseIsImmediate_DecreaseWaitsForTheNotice() public {
        uint256 v = _vault(COVERED);
        vaults.setCommitment(v, COVERED + 1);
        assertEq(lens.vault(v).commitment, COVERED + 1);
        assertEq(lens.vault(v).pendingCommitmentAt, 0);

        uint40 t0 = uint40(vm.getBlockTimestamp());
        vaults.setCommitment(v, 1e17);
        VaultView memory d = lens.vault(v);
        assertEq(d.commitment, COVERED + 1, "still the old value");
        assertEq(d.pendingCommitment, 1e17);
        assertEq(d.pendingCommitmentAt, t0 + 600);

        vm.warp(t0 + 599);
        vaults.checkpoint(v);
        assertEq(lens.vault(v).commitment, COVERED + 1, "not yet");
        vm.warp(t0 + 600);
        vaults.checkpoint(v);
        d = lens.vault(v);
        assertEq(d.commitment, 1e17, "applied at the first checkpoint after the notice");
        assertEq(d.pendingCommitmentAt, 0);
    }

    function test_SetCommitment_IncreaseCancelsAPendingDecrease() public {
        uint256 v = _vault(COVERED);
        vaults.setCommitment(v, 1e17);
        assertEq(lens.vault(v).pendingCommitment, 1e17);
        vaults.setCommitment(v, COVERED + 5);
        VaultView memory d = lens.vault(v);
        assertEq(d.pendingCommitment, 0);
        assertEq(d.pendingCommitmentAt, 0);
        assertEq(d.commitment, COVERED + 5);
    }

    function test_RevertWhen_SetCommitment_NotCurator() public {
        uint256 v = _vault(COVERED);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.NotCurator.selector, address(0xBAD)));
        vaults.setCommitment(v, 1);
    }

    // ─── coverage and breach ───

    function test_Breach_GraceClockThenFlag_ThenClearedByARerange() public {
        uint256 v = _vault(COVERED);
        vaults.setCommitment(v, UNCOVERED); // above what the wide vault commits
        uint40 t0 = uint40(vm.getBlockTimestamp());

        // The first checkpoint to see lost coverage starts the grace clock; no breach yet.
        vm.warp(t0 + 10);
        vm.expectEmit(true, false, false, true);
        emit IBallastEvents.CoverageLost(v, t0 + 10 + 300);
        vaults.checkpoint(v);
        assertEq(lens.vault(v).breachSince, 0);

        // Inside the grace: still no flag.
        vm.warp(t0 + 10 + 299);
        vaults.checkpoint(v);
        assertEq(lens.vault(v).breachSince, 0);
        assertEq(lens.vaultRecord(v).breachCount, 0);

        // After the grace the next checkpoint flags.
        vm.warp(t0 + 10 + 300);
        vm.expectEmit(true, false, false, false);
        emit IBallastEvents.BreachFlagged(v, 0, 0);
        vaults.checkpoint(v);
        assertEq(lens.vault(v).breachSince, t0 + 10 + 300);
        assertEq(lens.vaultRecord(v).breachCount, 1);
        (uint128 depth, uint128 commitment, bool inBreach) = lens.vaultStatus(v);
        assertTrue(inBreach);
        assertEq(commitment, UNCOVERED);
        assertLt(depth, commitment);
        assertEq(lens.committedDepth(), 0, "a vault in breach is excluded from committedDepth");

        // Flagging is once per episode.
        vm.warp(vm.getBlockTimestamp() + 60);
        vaults.checkpoint(v);
        assertEq(lens.vaultRecord(v).breachCount, 1);

        // Restoring coverage by lowering the commitment: the decrease applies after the notice, then it clears.
        vaults.setCommitment(v, COVERED);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.expectEmit(true, false, false, false);
        emit IBallastEvents.BreachCleared(v);
        vaults.checkpoint(v);
        assertEq(lens.vault(v).breachSince, 0);
        assertGt(lens.committedDepth(), 0);
    }

    function test_Breach_ClearsWhenRerangeRestoresCoverage() public {
        uint256 v = _vault(COVERED);
        // A vault that cannot reach the new commitment even after a re-range: it reverts instead (INV-7).
        vaults.setCommitment(v, UNCOVERED);
        vm.warp(vm.getBlockTimestamp() + 10);
        vaults.checkpoint(v);
        vm.warp(vm.getBlockTimestamp() + 300);
        vaults.checkpoint(v);
        assertGt(lens.vault(v).breachSince, 0);
        // Doubling the liquidity restores coverage (needs idle to fund it; none, so deposit first).
        vm.expectRevert(IBallastErrors.InsufficientIdle.selector); // 2e19 over the wide range is not fundable
        vaults.rerange(v, _one(-6000, 6000), _l(2e19));
        // A tighter range needs fewer tokens per unit of liquidity, so 1.3e19 is fundable and deep enough.
        vaults.rerange(v, _one(-1200, 1200), _l(1.3e19));
        assertEq(lens.vault(v).breachSince, 0, "R-COV-3: cleared by the re-range");
        assertGe(lens.vaultDepth(v), UNCOVERED);
    }

    function test_Breach_CoverageIsRecordedInTheCuratorRecord() public {
        uint256 v = _vault(COVERED);
        vm.warp(vm.getBlockTimestamp() + 100);
        vaults.checkpoint(v);
        CuratorRecord memory r = lens.vaultRecord(v);
        assertEq(r.trackedSeconds, 100);
        assertEq(r.coveredSeconds, 100);
        vaults.setCommitment(v, UNCOVERED);
        vm.warp(vm.getBlockTimestamp() + 50);
        vaults.checkpoint(v); // clock starts at this call; the 50 s before it were still covered
        vm.warp(vm.getBlockTimestamp() + 50);
        vaults.checkpoint(v);
        r = lens.vaultRecord(v);
        assertEq(r.trackedSeconds, 200);
        assertEq(r.coveredSeconds, 150, "the last 50 s were tracked but not covered");
    }
}
