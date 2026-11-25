// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Observations} from "../../../src/libraries/Observations.sol";
import {ObservationsHarness} from "../../utils/ObservationsHarness.sol";
import {ObservationsModel} from "../../utils/ObservationsModel.sol";

/// @notice Deterministic scenarios for `Observations`. Fuzz and differential tests are in
/// `test/fuzz/ObservationsDifferential.t.sol`; gas in `test/gas/ObservationsGas.t.sol`.
contract ObservationsTest is Test {
    ObservationsHarness internal h;
    ObservationsModel internal m;

    function setUp() public {
        h = new ObservationsHarness();
        m = new ObservationsModel();
    }

    function _init(uint40 t0, int24 tick, uint16 card) internal {
        h.initialize(t0, tick, card);
        m.init(t0, tick);
    }

    /// @dev A swap at `t` with the pool moving to `newTick`; the pre-swap tick is the model's current tick.
    function _swap(uint40 t, int24 newTick, uint32 interval) internal returns (bool snap) {
        snap = h.update(t, m.currentTick(), interval);
        m.swap(t, newTick);
    }

    /// @custom:requirement R-POOL-4
    function test_Initialize_SeedsSnapshotAndAccumulator() public {
        _init(1000, 77, 10);
        Observations.State memory st = h.state();
        assertEq(st.cardinality, 10);
        assertEq(st.index, 0);
        assertEq(st.lastSwapTs, 1000);
        assertEq(st.lastTick, 77);
        assertEq(st.cumulative, 0);
        assertEq(st.lastSnapshotTs, 1000);
        assertEq(h.length(), 1);
        assertEq(h.at(0).timestamp, 1000);
        assertEq(h.at(0).tickCumulative, 0);
    }

    /// @custom:requirement R-POOL-4
    function test_RevertWhen_InitializedTwiceOrWithZeroCardinality() public {
        vm.expectRevert(Observations.InvalidInitialization.selector);
        h.initialize(0, 0, 0);
        _init(0, 0, 4);
        vm.expectRevert(Observations.InvalidInitialization.selector);
        h.initialize(5, 0, 4);
    }

    /// @notice The reason for ADR-013: a swap skipped by the snapshot rate limit must still be accounted for, so the
    /// accumulator at the next swap equals the exact history (0 for 10 s, then 100 for 60 s).
    /// @custom:requirement R-ORC-1
    /// @custom:invariant INV-11
    function test_Update_AccumulatesEverySwap_EvenWhenSnapshotIsRateLimited() public {
        _init(0, 0, 8);
        assertFalse(_swap(10, 100, 60), "snapshot skipped: only 10 s since last");
        assertEq(h.state().cumulative, 0, "tick 0 held for 10 s");
        assertEq(h.length(), 1, "no snapshot written");
        assertFalse(_swap(40, -50, 60), "still skipped");
        assertEq(h.state().cumulative, 100 * 30, "tick 100 held 10..40");
        assertTrue(_swap(70, 5, 60), "70 s since the last snapshot: written");
        // 0*10 + 100*30 + (-50)*30 = 1500; exact, unlike a write that attributes the post-swap tick to the whole span.
        assertEq(h.state().cumulative, 1500);
        assertEq(h.at(1).tickCumulative, 1500);
        assertEq(h.at(1).tickCumulative, m.cumulativeAt(70));
    }

    /// @notice A snapshot is written exactly when `interval` seconds have passed since the previous one (boundary).
    /// @custom:requirement R-ORC-1
    function test_Update_SnapshotBoundary_IsInclusive() public {
        _init(0, 0, 8);
        assertFalse(_swap(59, 1, 60), "59 s: not yet");
        assertTrue(_swap(60, 2, 60), "exactly 60 s: written");
        assertEq(h.length(), 2);
        assertFalse(_swap(119, 3, 60), "59 s after the second snapshot");
        assertTrue(_swap(120, 4, 60), "exactly 60 s after");
        assertEq(h.state().lastSnapshotTs, 120);
    }

    /// @custom:requirement R-ORC-1
    function test_Update_RecordsPreSwapTickAndTimestamp() public {
        _init(0, 11, 8);
        _swap(30, 22, 60);
        Observations.State memory st = h.state();
        assertEq(st.lastTick, 11, "lastTick is the pre-swap tick of the last update");
        assertEq(st.lastSwapTs, 30);
        _swap(45, 33, 60);
        assertEq(h.state().lastTick, 22);
        assertEq(h.state().lastSwapTs, 45);
    }

    /// @custom:requirement R-ORC-1
    function test_Update_SameTimestampIsNoOp() public {
        _init(0, 0, 8);
        assertTrue(_swap(100, 40, 60));
        Observations.State memory before = h.state();
        assertFalse(h.update(100, 999, 60), "second swap in the same timestamp");
        Observations.State memory after_ = h.state();
        assertEq(after_.cumulative, before.cumulative);
        assertEq(after_.lastTick, before.lastTick, "lastTick untouched by the no-op");
        assertEq(h.length(), 2);
    }

    /// @custom:requirement R-ORC-1
    function test_RevertWhen_TimeRegresses() public {
        _init(100, 0, 4);
        vm.expectRevert(
            abi.encodeWithSelector(Observations.TimeRegression.selector, uint40(99), uint40(100))
        );
        h.update(99, 0, 60);
        vm.expectRevert(
            abi.encodeWithSelector(Observations.TimeRegression.selector, uint40(99), uint40(100))
        );
        h.cumulativeNow(99, 0);
        vm.expectRevert(
            abi.encodeWithSelector(Observations.TimeRegression.selector, uint40(99), uint40(100))
        );
        h.cumulativeAt(99, 0, 0);
    }

    /// @custom:requirement R-ORC-1
    function test_RevertWhen_CumulativeLeavesInt56() public {
        _init(0, 0, 4);
        vm.expectRevert();
        h.update(uint40(1) << 39, 887_272, 60); // 887272 * 2^39 > 2^55
    }

    /// @notice The current cumulative is exact between swaps because the tick is constant (R-ORC-3).
    /// @custom:requirement R-ORC-3
    function test_CumulativeNow_ExtendsWithCurrentTick() public {
        _init(0, 10, 8);
        _swap(100, -30, 60);
        for (uint40 t = 100; t <= 500; t += 77) {
            assertEq(int256(h.cumulativeNow(t, -30)), m.cumulativeAt(t));
        }
    }

    /// @notice Every snapshot value equals the exact history at its timestamp (INV-11).
    /// @custom:requirement R-ORC-3
    /// @custom:invariant INV-11
    function test_SnapshotValues_AreExact() public {
        _init(0, 5, 16);
        int24[6] memory ticks = [int24(-100), 250, -7, 3000, -3000, 0];
        uint40 t = 0;
        for (uint256 i; i < ticks.length; ++i) {
            t += uint40(13 + 29 * i);
            _swap(t, ticks[i], 20);
        }
        for (uint256 i; i < h.length(); ++i) {
            assertEq(
                int256(h.at(i).tickCumulative), m.cumulativeAt(h.at(i).timestamp), "snapshot exact"
            );
            if (i > 0) {
                assertGt(h.at(i).timestamp, h.at(i - 1).timestamp, "timestamps strictly increase");
            }
        }
    }

    /// @notice When every swap is far enough apart to be snapshotted, interpolation is exact.
    /// @custom:requirement R-ORC-3
    function test_Interpolation_IsExact_WhenEverySwapIsSnapshotted() public {
        _init(0, 0, 32);
        int24[5] memory ticks = [int24(120), -40, 500, -500, 7];
        uint40 t;
        for (uint256 i; i < ticks.length; ++i) {
            t += 100;
            assertTrue(_swap(t, ticks[i], 60));
        }
        uint40 nowTs = t + 50;
        int24 cur = m.currentTick();
        for (uint32 ago = 0; ago <= nowTs; ago += 17) {
            (int56 got, bool warm) = h.cumulativeAt(nowTs, ago, cur);
            assertTrue(warm);
            assertEq(
                int256(got),
                m.cumulativeAt(nowTs - ago),
                "exact when no swap lies between snapshots"
            );
        }
    }

    /// @notice With rate-limited snapshots the interpolation error is bounded by `interval * tick swing` (MATH §4).
    /// @custom:requirement R-ORC-3
    function test_Interpolation_ErrorWithinDocumentedBound() public {
        uint32 interval = 60;
        _init(0, 0, 16);
        // Skipped swaps inside the first interval after the snapshot at 0, then a quiet stretch.
        _swap(5, 400, interval);
        _swap(20, -300, interval);
        _swap(55, 250, interval);
        _swap(200, 0, interval); // snapshot at 200
        uint40 nowTs = 260;
        int24 cur = m.currentTick();
        uint256 maxErr;
        for (uint32 ago = 60; ago < 260; ++ago) {
            (int56 got,) = h.cumulativeAt(nowTs, ago, cur);
            int256 diff = int256(got) - m.cumulativeAt(nowTs - ago);
            uint256 err = uint256(diff < 0 ? -diff : diff);
            if (err > maxErr) maxErr = err;
        }
        // Swing over the first interval is 400 - (-300) = 700 ticks.
        assertLe(maxErr, uint256(interval) * 700 + 1);
        assertGt(maxErr, 0, "the bound is not vacuous: skipped swaps do create error");
    }

    /// @custom:requirement R-ORC-2
    function test_TwapTick_RoundsTowardNegativeInfinity() public {
        _init(0, -2, 8);
        _swap(2, -1, 1); // tick -2 for 2 s
        // At t = 5: cumulative = -2*2 + -1*3 = -7 over a 5 s window = -1.4 -> floor = -2.
        (int24 tick, bool warm) = h.twapTick(5, 5, -1);
        assertTrue(warm);
        assertEq(tick, -2);
        assertEq(int256(tick), m.twap(5, 5));
        // Positive values round down as well: +1.4 -> 1.
        ObservationsHarness h2 = new ObservationsHarness();
        h2.initialize(0, 2, 8);
        h2.update(2, 2, 1);
        (int24 t2,) = h2.twapTick(5, 5, 1);
        assertEq(t2, 1);
    }

    /// @custom:requirement R-ORC-2
    function test_TwapTick_ConstantTickIsExact() public {
        _init(0, 1234, 8);
        _swap(10_000, 1234, 60);
        (int24 tick, bool warm) = h.twapTick(20_000, 5000, 1234);
        assertTrue(warm);
        assertEq(tick, 1234);
    }

    /// @custom:requirement R-ORC-2
    function test_RevertWhen_WindowIsZero() public {
        _init(0, 0, 8);
        vm.expectRevert(Observations.ZeroWindow.selector);
        h.twapTick(10, 0, 0);
    }

    /// @notice Not warm: TWAP is over the actual elapsed time since the oldest snapshot (R-ORC-6).
    /// @custom:requirement R-ORC-4 R-ORC-6
    function test_ColdHistory_UsesActualElapsedTime() public {
        _init(1000, 50, 8);
        (int24 tick, bool warm) = h.twapTick(1100, 3600, 50);
        assertFalse(warm);
        assertEq(tick, 50, "constant 50 over the 100 s that exist");
        // No elapsed time at all: current tick.
        (int24 t0, bool w0) = h.twapTick(1000, 3600, 77);
        assertFalse(w0);
        assertEq(t0, 77);
        // A target before the epoch is cold too.
        (int56 c, bool w1) = h.cumulativeAt(1100, 5000, 50);
        assertFalse(w1);
        assertEq(c, 0, "returns the oldest snapshot's cumulative");
    }

    /// @custom:requirement R-ORC-4 R-ORC-7
    /// @custom:invariant INV-15
    function test_IsWarm_BecomesTrueWhenWindowCovered() public {
        _init(1000, 0, 8);
        assertFalse(h.isWarm(1000, 100));
        assertFalse(h.isWarm(1099, 100));
        assertTrue(h.isWarm(1100, 100));
        assertTrue(h.isWarm(5000, 100));
    }

    /// @notice Ring wrap-around: after the ring is full the oldest snapshot is overwritten in order.
    /// @custom:requirement R-ORC-5
    /// @custom:invariant INV-11
    function test_RingWrapsAndKeepsOrder() public {
        _init(0, 0, 4);
        uint32 interval = 10;
        int24[9] memory ticks = [int24(10), -20, 30, -40, 50, -60, 70, -80, 90];
        uint40 t;
        for (uint256 i; i < ticks.length; ++i) {
            t += 10;
            assertTrue(_swap(t, ticks[i], interval));
        }
        assertEq(h.length(), 4, "ring never exceeds cardinality");
        // Newest four snapshots are at t = 60, 70, 80, 90 (swaps at 10..90 each snapshot; initial at 0).
        uint256 base = h.state().index;
        uint40[4] memory expected = [uint40(60), 70, 80, 90];
        for (uint256 i; i < 4; ++i) {
            Observations.Observation memory o = h.at((base + 1 + i) % 4);
            assertEq(o.timestamp, expected[i], "oldest-first order after wrap");
            assertEq(int256(o.tickCumulative), m.cumulativeAt(o.timestamp));
        }
        int24 cur = m.currentTick();
        // Retained history: queries at and after t=60 are warm and exact.
        for (uint32 ago = 0; ago <= 30; ++ago) {
            (int56 got, bool warm) = h.cumulativeAt(90, ago, cur);
            assertTrue(warm);
            assertEq(int256(got), m.cumulativeAt(90 - ago));
        }
        // Older than the oldest retained snapshot is cold.
        (, bool warmOld) = h.cumulativeAt(90, 31, cur);
        assertFalse(warmOld);
        assertTrue(h.isWarm(90, 30));
        assertFalse(h.isWarm(90, 31));
    }

    /// @notice With cardinality one below the hard minimum, warm can regress; at the minimum it cannot. This shows
    /// why R-ORC-5's `+ 1` exists (R-ORC-7).
    /// @custom:requirement R-ORC-5 R-ORC-7
    /// @custom:invariant INV-15
    function test_Warm_RegressesBelowMinimumCardinality_ButNotAtMinimum() public {
        uint32 window = 100;
        uint32 interval = 10;
        // Minimum = ceil(100 / 10) + 1 = 11. Test 10 (below) and 11 (at minimum), a sparse start followed by swaps exactly one interval apart.
        for (uint16 card = 10; card <= 11; ++card) {
            ObservationsHarness hh = new ObservationsHarness();
            hh.initialize(0, 0, card);
            bool wasWarm;
            bool regressed;
            // A sparse start (first swap at 100 s) lets the oldest snapshot be the epoch for a while; dense swaps
            // then fill the ring and overwrite it.
            hh.update(100, 0, interval);
            wasWarm = hh.isWarm(100, window);
            assertTrue(wasWarm, "covered by the epoch snapshot");
            for (uint40 t = 110; t <= 500; t += 10) {
                hh.update(t, 0, interval);
                bool w = hh.isWarm(t, window);
                if (wasWarm && !w) regressed = true;
                wasWarm = wasWarm || w;
            }
            if (card == 10) assertTrue(regressed, "below the minimum, warm regresses");
            else assertFalse(regressed, "at the minimum, warm is monotonic");
        }
    }
}
