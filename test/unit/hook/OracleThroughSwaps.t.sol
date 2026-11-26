// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "../../utils/HookFixture.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {ObservationsModel} from "../../utils/ObservationsModel.sol";
import {Observations} from "../../../src/libraries/Observations.sol";
import {Config} from "../../../src/types/Types.sol";

/// @notice The oracle driven by real swaps on a real PoolManager through the real hook, against the naive
/// full-history model (R-ORC-1..3, INV-11, ADR-013).
/// @custom:requirement R-ORC-1 R-ORC-2 R-ORC-3 R-ORC-4
contract OracleThroughSwapsTest is HookFixture {
    ObservationsModel internal model;
    uint40 internal initTs;

    function setUp() public {
        Config memory c = ConfigFixture.compressed();
        _setUpDefault(true, c, 0);
        _provide(-12_000, 12_000, 1e19);
        model = new ObservationsModel();
        model.init(vm.getBlockTimestamp(), 0);
        initTs = uint40(vm.getBlockTimestamp());
    }

    /// @dev One real swap; the model learns the post-swap tick at the swap's timestamp.
    function _modelSwap(bool sellCollateral, uint256 amount) internal {
        _swap(sellCollateral, amount);
        model.swap(vm.getBlockTimestamp(), _tick());
    }

    function _logicalSnapshot(uint256 i) internal view returns (Observations.Observation memory) {
        uint256 len = hook.obsLength();
        Observations.State memory st = hook.obsState();
        uint256 phys = len < st.cardinality ? i : (uint256(st.index) + 1 + i) % len;
        return hook.obsAt(phys);
    }

    /// @notice Two swaps in one timestamp accumulate once; the second adds no weight (R-ORC-1).
    function test_SameTimestampDoubleSwap_AccumulatesOnce() public {
        vm.warp(vm.getBlockTimestamp() + 100);
        _modelSwap(true, 1e17);
        Observations.State memory a = hook.obsState();
        int24 tickAfterFirst = _tick();
        assertTrue(tickAfterFirst != 0, "first swap moved the price");
        _modelSwap(false, 5e5); // same timestamp, opposite direction
        Observations.State memory b = hook.obsState();
        assertEq(b.cumulative, a.cumulative, "no second accumulation");
        assertEq(b.lastSwapTs, a.lastSwapTs);
        assertEq(hook.obsLength(), 2, "one snapshot beyond the seed");
        // The first swap's pre-swap tick (0) carried the whole 100 s: cumulative is 0.
        assertEq(int256(a.cumulative), 0);
        assertEq(a.lastTick, 0);
    }

    /// @notice A swap pair that moves the price and moves it back within one block carries zero weight.
    function test_InBlockRoundTrip_HasNoOracleWeight() public {
        vm.warp(vm.getBlockTimestamp() + 100);
        int24 before_ = _tick();
        _modelSwap(true, 3e17);
        _modelSwap(false, 1e8);
        // Time passes with the (displaced) tick.
        vm.warp(vm.getBlockTimestamp() + 50);
        _modelSwap(true, 1e6);
        Observations.State memory st = hook.obsState();
        // Accumulated: tick 0 for 100 s (pre-swap tick of the first swap), then the displaced tick for 50 s.
        assertEq(int256(st.cumulative), model.cumulativeAt(vm.getBlockTimestamp()), "exact vs model");
        assertEq(before_, 0);
    }

    /// @notice Sparse swaps: long silences, then bursts. The accumulator and all snapshots are exact.
    function test_SparseSwaps_AccumulatorExact() public {
        uint256[6] memory gaps = [uint256(7), 3600, 1, 86_400, 59, 61];
        for (uint256 i; i < gaps.length; ++i) {
            vm.warp(vm.getBlockTimestamp() + gaps[i]);
            _modelSwap(i % 2 == 0, 2e16 + i * 1e15);
        }
        Observations.State memory st = hook.obsState();
        assertEq(int256(st.cumulative), model.cumulativeAt(st.lastSwapTs), "accumulator");
        for (uint256 i; i < hook.obsLength(); ++i) {
            Observations.Observation memory o = _logicalSnapshot(i);
            assertEq(int256(o.tickCumulative), model.cumulativeAt(o.timestamp), "snapshot exact");
        }
    }

    /// @notice A fuzzed history driven by real swaps matches the model: accumulator, snapshots, strictly increasing
    /// timestamps (INV-11) and TWAPs within the documented bound.
    /// forge-config: default.fuzz.runs = 150
    /// forge-config: ci.fuzz.runs = 1500
    /// @custom:invariant INV-11
    function testFuzz_RealSwapHistory_MatchesNaiveModel(uint256 seed, uint8 stepsRaw) public {
        uint256 steps = bound(stepsRaw, 3, 120);
        for (uint256 i; i < steps; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            uint256 mode = x % 8;
            vm.warp(
                vm.getBlockTimestamp() + (mode == 0 ? 0 : mode == 1 ? (x >> 8) % 7200 : (x >> 8) % 90 + 1)
            );
            _modelSwap((x >> 100) % 2 == 0, 1e12 + (x >> 120) % 4e16);
        }
        vm.warp(vm.getBlockTimestamp() + (uint256(keccak256(abi.encode(seed, "q"))) % 120));

        Observations.State memory st = hook.obsState();
        assertEq(int256(st.cumulative), model.cumulativeAt(st.lastSwapTs), "accumulator exact");
        uint256 prev;
        for (uint256 i; i < hook.obsLength(); ++i) {
            Observations.Observation memory o = _logicalSnapshot(i);
            assertEq(int256(o.tickCumulative), model.cumulativeAt(o.timestamp), "snapshot exact");
            if (i > 0) assertGt(o.timestamp, prev, "timestamps strictly increase");
            prev = o.timestamp;
        }
        _checkTwap(300);
        _checkTwap(1800);
        _checkTwap(3600);
    }

    /// @dev The bound of MATH §4 is `interval * swing / window` where `swing` is the tick swing over the bracket
    /// `[a, b]` of snapshots around the window start (not over the window: the bracket can be hours long and begin
    /// before the window). Finds the bracket from the retained snapshots.
    function _checkTwap(uint32 window) internal view {
        (int24 got, bool warm) = hook.twapTick(window);
        if (!warm) return;
        int256 exact = model.twap(vm.getBlockTimestamp(), window);
        int256 diff = int256(got) - exact;
        uint256 err = uint256(diff < 0 ? -diff : diff);
        uint256 target = vm.getBlockTimestamp() - window;
        uint256 aTs;
        uint256 bTs = hook.obsState().lastSwapTs;
        for (uint256 i; i < hook.obsLength(); ++i) {
            uint256 ts = _logicalSnapshot(i).timestamp;
            if (ts <= target) {
                aTs = ts;
            } else {
                bTs = ts;
                break;
            }
        }
        uint256 swing = model.swing(aTs, bTs);
        // error <= ceil(interval * swing / window) + 1 (the +1 covers floor rounding)
        uint256 bound_ = (uint256(cfg.observationInterval) * swing + window - 1) / window + 1;
        assertLe(err, bound_, "TWAP within documented bound");
    }

    /// @notice An attacker times swaps just after each snapshot to push the price and just before the next to revert
    /// it. The accumulator stays exact; the TWAP error stays within the documented bound, and is nonzero (the attack
    /// is not vacuous) (T3/T4, MATH §4).
    function test_AdversarialSwapTiming_ErrorBoundHolds() public {
        uint256 maxErr;
        for (uint256 k; k < 70; ++k) {
            vm.warp(vm.getBlockTimestamp() + 1);
            _modelSwap(true, 4e17); // push down right after a boundary
            vm.warp(vm.getBlockTimestamp() + 57);
            _modelSwap(false, 1e18); // pull back just before the next
            vm.warp(vm.getBlockTimestamp() + 2);
            _modelSwap(true, 1e5); // the boundary swap writes the snapshot
        }
        // Query off the snapshot grid so that window starts fall inside a snapshot interval.
        vm.warp(vm.getBlockTimestamp() + 17);
        Observations.State memory st = hook.obsState();
        assertEq(int256(st.cumulative), model.cumulativeAt(st.lastSwapTs), "accumulator exact");
        for (uint32 w = 300; w <= 3000; w += 300) {
            (int24 got, bool warm) = hook.twapTick(w);
            assertTrue(warm);
            int256 diff = int256(got) - model.twap(vm.getBlockTimestamp(), w);
            uint256 err = uint256(diff < 0 ? -diff : diff);
            if (err > maxErr) maxErr = err;
            _checkTwap(w);
        }
        emit log_named_uint("max TWAP error (ticks) under adversarial timing", maxErr);
        assertGt(
            maxErr, 0, "the attack must actually perturb the TWAP, or the bound check is vacuous"
        );
    }

    /// @notice Cold oracle: before the window is covered, `warm` is false and the average is over the elapsed time.
    function test_ColdThenWarm_Transition() public {
        (, bool warm) = hook.twapTick(3600);
        assertFalse(warm);
        for (uint256 i; i < 62; ++i) {
            vm.warp(vm.getBlockTimestamp() + 60);
            _modelSwap(i % 2 == 0, 1e12);
        }
        (, warm) = hook.twapTick(3600);
        assertTrue(warm, "warm once the oldest snapshot is an anchor window old");
        assertEq(hook.obsLength() > 61, true);
    }
}
