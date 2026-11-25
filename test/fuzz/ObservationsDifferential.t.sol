// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Observations} from "../../src/libraries/Observations.sol";
import {ObservationsHarness} from "../utils/ObservationsHarness.sol";
import {ObservationsModel} from "../utils/ObservationsModel.sol";

/// @notice Differential and property tests of `Observations` against a naive full-history model, with adversarial
/// swap patterns (many swaps inside one snapshot interval, same-timestamp swaps, extreme ticks).
contract ObservationsDifferentialTest is Test {
    ObservationsHarness internal h;
    ObservationsModel internal m;

    struct Run {
        uint32 interval;
        uint40 nowTs;
        int24 currentTick;
    }

    function _drive(uint256 seed, uint32 interval, uint16 card, uint256 steps)
        internal
        returns (Run memory r)
    {
        h = new ObservationsHarness();
        m = new ObservationsModel();
        h.initialize(1000, 0, card);
        m.init(1000, 0);
        uint40 t = 1000;
        r.interval = interval;
        for (uint256 i; i < steps; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            // dt in [0, 3*interval]: zero (same timestamp), inside an interval, or beyond one.
            t += uint40(x % (3 * uint256(interval) + 1));
            // Mostly moderate ticks with occasional extremes.
            int24 newTick = (x >> 64) % 16 == 0
                ? int24(int256((x >> 72) % 1_774_545) - 887_272)
                : int24(int256((x >> 72) % 4001) - 2000);
            h.update(t, m.currentTick(), interval);
            m.swap(t, newTick);
        }
        // Query a little after the last swap.
        r.nowTs = t + uint40(uint256(keccak256(abi.encode(seed, "q"))) % 90);
        r.currentTick = m.currentTick();
    }

    /// @notice The running accumulator, the exact current cumulative and every snapshot are exact against the model,
    /// whatever the swap pattern and snapshot rate limit (ADR-013).
    /// forge-config: default.fuzz.runs = 300
    /// forge-config: ci.fuzz.runs = 3000
    /// @custom:requirement R-ORC-1 R-ORC-3
    /// @custom:invariant INV-11
    function testFuzz_AccumulatorAndSnapshotsAreExact(
        uint256 seed,
        uint8 intervalRaw,
        uint8 stepsRaw
    ) public {
        uint32 interval = uint32(bound(intervalRaw, 1, 120));
        Run memory r = _drive(seed, interval, 64, bound(stepsRaw, 1, 60));

        assertEq(
            int256(h.cumulativeNow(r.nowTs, r.currentTick)),
            m.cumulativeAt(r.nowTs),
            "cumulative now"
        );
        uint256 len = h.length();
        uint256 prevTs;
        Observations.State memory st = h.state();
        for (uint256 i; i < len; ++i) {
            // Logical (oldest-first) order for wrapped or unwrapped rings.
            uint256 phys = len < st.cardinality ? i : (uint256(st.index) + 1 + i) % len;
            Observations.Observation memory o = h.at(phys);
            assertEq(int256(o.tickCumulative), m.cumulativeAt(o.timestamp), "snapshot exact");
            if (i > 0) assertGt(o.timestamp, prevTs, "strictly increasing timestamps");
            prevTs = o.timestamp;
        }
    }

    /// @dev Checks one `cumulativeAt` query against the model (exact or within the documented bound).
    function _checkTarget(Run memory r, uint32 ago) internal view {
        Observations.State memory st = h.state();
        (int56 got, bool warm) = h.cumulativeAt(r.nowTs, ago, r.currentTick);
        assertTrue(warm, "history reaches the epoch while the ring has not wrapped");
        uint256 target = r.nowTs - ago;
        int256 diff = int256(got) - m.cumulativeAt(target);
        uint256 err = uint256(diff < 0 ? -diff : diff);
        if (target >= st.lastSwapTs) {
            assertEq(err, 0, "exact at or after the last update");
            return;
        }
        // Bracketing snapshot times (ring not wrapped: physical == logical).
        uint256 aTs;
        uint256 bTs = st.lastSwapTs;
        uint256 len = h.length();
        for (uint256 i; i < len; ++i) {
            uint256 ts = h.at(i).timestamp;
            if (ts <= target) {
                aTs = ts;
            } else {
                bTs = ts;
                break;
            }
        }
        if (aTs == target) {
            assertEq(err, 0, "exact at a snapshot time");
            return;
        }
        assertLe(
            err,
            uint256(r.interval) * m.swing(aTs, bTs) + 1,
            "interpolation error within interval * swing"
        );
    }

    /// @notice `cumulativeAt` at arbitrary past times: exact when the target is at or after the last update or at a
    /// snapshot time; otherwise within `interval * swing(bracket)` (+1 for the floor) of the exact value (MATH §4).
    /// forge-config: default.fuzz.runs = 200
    /// forge-config: ci.fuzz.runs = 2000
    /// @custom:requirement R-ORC-3
    function testFuzz_CumulativeAt_WithinDocumentedBound(
        uint256 seed,
        uint8 intervalRaw,
        uint8 stepsRaw
    ) public {
        uint32 interval = uint32(bound(intervalRaw, 1, 120));
        Run memory r = _drive(seed, interval, 128, bound(stepsRaw, 1, 60));
        for (uint256 k; k < 8; ++k) {
            uint32 ago =
                uint32(uint256(keccak256(abi.encode(seed, "ago", k))) % (r.nowTs - 1000 + 1));
            _checkTarget(r, ago);
        }
    }

    /// @notice TWAP against the model: error at most `ceil(interval * swing / window) + 1`.
    /// forge-config: default.fuzz.runs = 200
    /// forge-config: ci.fuzz.runs = 2000
    /// @custom:requirement R-ORC-2 R-ORC-3
    function testFuzz_Twap_WithinDocumentedBound(
        uint256 seed,
        uint8 intervalRaw,
        uint8 stepsRaw,
        uint16 windowRaw
    ) public {
        uint32 interval = uint32(bound(intervalRaw, 1, 120));
        Run memory r = _drive(seed, interval, 128, bound(stepsRaw, 1, 60));
        uint32 window = uint32(bound(windowRaw, 1, r.nowTs - 1000 > 1 ? r.nowTs - 1000 : 1));
        if (r.nowTs - 1000 < window) return; // window longer than history: covered by the cold test
        (int24 got, bool warm) = h.twapTick(r.nowTs, window, r.currentTick);
        assertTrue(warm);
        int256 exact = m.twap(r.nowTs, window);
        int256 diff = int256(got) - exact;
        uint256 err = uint256(diff < 0 ? -diff : diff);
        uint256 sw = m.swing(1000, r.nowTs);
        uint256 maxErr = (uint256(interval) * sw + window - 1) / window + 1;
        assertLe(err, maxErr, "twap error within interval * swing / window (+1)");
    }

    /// @notice Warm is monotonic at the hard-minimum cardinality, for any swap pattern (R-ORC-7, INV-15).
    /// forge-config: default.fuzz.runs = 300
    /// forge-config: ci.fuzz.runs = 3000
    /// @custom:requirement R-ORC-5 R-ORC-7
    /// @custom:invariant INV-15
    function testFuzz_Warm_IsMonotonic_AtMinimumCardinality(
        uint256 seed,
        uint8 intervalRaw,
        uint16 windowRaw,
        uint8 stepsRaw
    ) public {
        uint32 interval = uint32(bound(intervalRaw, 1, 30));
        uint32 window = uint32(bound(windowRaw, interval, 600));
        uint16 minCard = uint16((uint256(window) + interval - 1) / interval + 1);
        h = new ObservationsHarness();
        h.initialize(0, 0, minCard);
        uint40 t;
        bool wasWarm;
        for (uint256 i; i < bound(stepsRaw, 1, 200); ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            // Mix sparse and dense swaps; dt in [0, 6 * interval].
            t += uint40(x % (6 * uint256(interval) + 1));
            h.update(t, int24(int256(x >> 64) % 1000), interval);
            bool w = h.isWarm(t, window);
            assertFalse(wasWarm && !w, "warm regressed");
            // Also between swaps (time passing only helps).
            bool later = h.isWarm(t + 1000, window);
            assertTrue(!w || later, "warm regressed as time passed");
            wasWarm = wasWarm || w;
        }
    }
}
