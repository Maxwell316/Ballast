// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Observations} from "../../src/libraries/Observations.sol";
import {ObservationsHarness} from "../utils/ObservationsHarness.sol";

/// @notice Differential test of the search cursors (ADR-038, R-ORC-8): `cumulativeAtHinted` must return exactly what
/// the plain binary search returns, for every history and every hint, including cursors carried across ring
/// wraparound, long gaps, cold starts and arbitrary garbage.
contract ObservationsCursorTest is Test {
    ObservationsHarness internal h;

    struct Walk {
        Observations.Cursor aCur;
        Observations.Cursor sCur;
        uint256 hintedUses; // lookups where the carried cursor advanced the search
        uint256 wraps;
    }

    function _assertSame(uint40 nowTs, uint32 ago, int24 tick, Observations.Cursor memory hint)
        internal
        returns (Observations.Cursor memory next)
    {
        (int56 c1, bool w1) = h.cumulativeAt(nowTs, ago, tick);
        (int56 c2, bool w2, Observations.Cursor memory n) =
            h.cumulativeAtHinted(nowTs, ago, tick, hint);
        assertEq(c2, c1, "cumulative differs from binary search");
        assertEq(w2, w1, "warm differs from binary search");
        return n;
    }

    /// @custom:requirement R-ORC-8
    /// forge-config: default.fuzz.runs = 300
    /// forge-config: ci.fuzz.runs = 3000
    function testFuzz_HintedEqualsBinarySearch_CarriedAcrossHistory(
        uint256 seed,
        uint8 cardRaw,
        uint8 stepsRaw
    ) public {
        uint32 interval = 30;
        uint16 card = uint16(bound(cardRaw, 3, 40)); // small, so the ring wraps often
        h = new ObservationsHarness();
        h.initialize(1000, 0, card);
        uint40 t = 1000;
        int24 tick;
        Walk memory w;
        uint32 aWin = uint32(uint256(card - 1) * interval); // widest window the ring can keep warm
        uint32 sWin = aWin / 4 + 1;
        uint256 steps = bound(stepsRaw, 5, 200);
        for (uint256 i; i < steps; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            // Mostly regular gaps, sometimes zero, sometimes very long (cursor goes far behind).
            uint256 mode = x % 10;
            t += uint40(
                mode == 0
                    ? 0
                    : mode == 1
                        ? (x >> 8) % (interval * uint256(card) * 3)
                        : (x >> 8) % (2 * interval) + 1
            );
            h.update(t, tick, interval);
            tick = int24(int256((x >> 40) % 4001) - 2000);
            // Evaluate sometimes, like the hook does once per snapshot.
            if ((x >> 100) % 3 != 0) continue;
            w.aCur = _assertSame(t, aWin, tick, w.aCur);
            w.sCur = _assertSame(t, sWin, tick, w.sCur);
            // A query a little after the last update, with the same carried cursor.
            _assertSame(t + 7, sWin, tick, w.sCur);
        }
    }

    /// @notice Arbitrary garbage cursors never change the answer.
    /// @custom:requirement R-ORC-8
    /// forge-config: default.fuzz.runs = 300
    /// forge-config: ci.fuzz.runs = 3000
    function testFuzz_GarbageCursor_NeverChangesAnswer(
        uint256 seed,
        uint16 hIdx,
        uint40 hTs,
        uint8 stepsRaw
    ) public {
        uint32 interval = 20;
        h = new ObservationsHarness();
        h.initialize(5000, 0, 25);
        uint40 t = 5000;
        uint256 steps = bound(stepsRaw, 1, 90);
        for (uint256 i; i < steps; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            t += uint40(x % 70 + 1);
            h.update(t, int24(int256((x >> 200) % 3001) - 1500), interval);
        }
        uint40 q = t + 3;
        for (uint32 ago = 1; ago < 600; ago += 37) {
            _assertSame(q, ago, 5, Observations.Cursor(hIdx, hTs));
            // A cursor whose timestamp is a real snapshot's but whose index is wrong, and vice versa.
            _assertSame(q, ago, 5, Observations.Cursor(uint16(hIdx % 25), t - ago));
        }
    }

    /// @notice A cursor that points at a slot since overwritten by the ring is rejected (stale) and the answer is
    /// still right.
    /// @custom:requirement R-ORC-8
    function test_StaleCursorAfterWraparound_FallsBack() public {
        uint32 interval = 10;
        h = new ObservationsHarness();
        h.initialize(1000, 0, 6);
        uint40 t = 1000;
        for (uint256 i; i < 6; ++i) {
            t += interval;
            h.update(t, int24(int256(i) * 10), interval);
        }
        // Cursor at an old snapshot.
        (,, Observations.Cursor memory cur) =
            h.cumulativeAtHinted(t, 35, 50, Observations.Cursor(0, 0));
        // Wrap the ring several times so that slot is overwritten.
        for (uint256 i; i < 20; ++i) {
            t += interval;
            h.update(t, int24(int256(i)), interval);
        }
        assertEq(
            h.at(cur.index).timestamp != cur.timestamp, true, "slot should have been overwritten"
        );
        _assertSame(t, 40, 3, cur);
    }

    /// @notice The walk from a valid cursor is bounded: after a long gap the answer still matches.
    /// @custom:requirement R-ORC-8
    function test_LongGapAfterValidCursor_MatchesBinarySearch() public {
        uint32 interval = 10;
        h = new ObservationsHarness();
        h.initialize(1000, 0, 200);
        uint40 t = 1000;
        for (uint256 i; i < 100; ++i) {
            t += interval;
            h.update(t, int24(int256(i % 7)), interval);
        }
        (,, Observations.Cursor memory cur) =
            h.cumulativeAtHinted(t, 900, 2, Observations.Cursor(0, 0));
        for (uint256 i; i < 90; ++i) {
            t += interval;
            h.update(t, int24(int256(i % 5)), interval);
        }
        // The window start moved ~90 snapshots forward since `cur`: far more than MAX_CURSOR_STEPS.
        _assertSame(t, 900, 2, cur);
    }

    /// @notice Zeroed hint (cold start) equals binary search; hint with timestamp above the target is ignored.
    /// @custom:requirement R-ORC-8
    function test_ZeroAndFutureHints_AreIgnored() public {
        h = new ObservationsHarness();
        h.initialize(1000, 0, 10);
        uint40 t = 1000;
        for (uint256 i; i < 8; ++i) {
            t += 10;
            h.update(t, int24(int256(i)), 10);
        }
        _assertSame(t, 35, 1, Observations.Cursor(0, 0));
        _assertSame(t, 35, 1, Observations.Cursor(3, t)); // timestamp after the target
    }
}
