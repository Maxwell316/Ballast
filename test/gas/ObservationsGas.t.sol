// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ObservationsHarness} from "../utils/ObservationsHarness.sol";

/// @notice Measures the gas of each oracle path with cold storage (ADR-036). Numbers are internal to the library
/// call (they exclude the external call into the harness). They are recorded in `.gas-snapshot` (via `forge snapshot`),
/// logged here, and tabulated in docs/TESTING.md. `beforeSwap` may use only the O(1) `update` paths; the binary search
/// (`twapTick`) belongs to the stress-evaluation path (at most once per interval) and to views.
contract ObservationsGasRingFillingTest is Test {
    uint16 internal constant CARDINALITY = 1585; // ceil(86400 / 60) + 1 = 1441 minimum, 1.1x margin
    uint32 internal constant INTERVAL = 60;
    ObservationsHarness internal h;
    uint40 internal t;

    function setUp() public {
        h = new ObservationsHarness();
        h.initialize(1000, 0, CARDINALITY);
        t = 1000;
    }

    /// @custom:requirement R-ORC-1
    function test_Gas_Update_SameTimestamp() public {
        t += INTERVAL;
        h.update(t, 5, INTERVAL);
        vm.cool(address(h));
        uint256 used = h.gasUpdate(t, 5, INTERVAL);
        emit log_named_uint("update, same timestamp (no-op)", used);
        assertLt(used, 5000);
    }

    /// @notice The per-swap hot path when no snapshot is due: one packed slot read and write.
    /// @custom:requirement R-ORC-1
    function test_Gas_Update_AccumulateOnly() public {
        t += INTERVAL;
        h.update(t, 5, INTERVAL);
        vm.cool(address(h));
        uint256 used = h.gasUpdate(t + 10, 7, INTERVAL);
        emit log_named_uint("update, accumulate only", used);
        assertLt(used, 12_000);
    }

    /// @notice First fill of the ring: accumulate plus a push (new slot).
    /// @custom:requirement R-ORC-1
    function test_Gas_Update_AccumulateAndPushSnapshot() public {
        vm.cool(address(h));
        uint256 used = h.gasUpdate(t + INTERVAL, 7, INTERVAL);
        emit log_named_uint("update, accumulate + snapshot push (ring filling)", used);
        assertLt(used, 50_000);
    }

    /// @notice Steady state: accumulate plus overwrite of the oldest snapshot.
    /// @notice The evaluation path: one TWAP over the full anchor window of a full ring (binary search over 1585 slots).
    /// The stress evaluation needs two TWAPs (anchor and short).
}

/// @dev Same measurements with a full ring (the steady state). The ring is filled in `setUp`, so the numbers in
/// `.gas-snapshot` are not dominated by the fill.
contract ObservationsGasFullRingTest is Test {
    uint16 internal constant CARDINALITY = 1585; // ceil(86400 / 60) + 1 = 1441 minimum, 1.1x margin
    uint32 internal constant INTERVAL = 60;
    ObservationsHarness internal h;
    uint40 internal t;

    function setUp() public {
        h = new ObservationsHarness();
        h.initialize(1000, 0, CARDINALITY);
        t = 1000;
        for (uint256 i; i < CARDINALITY + 20; ++i) {
            t += INTERVAL;
            h.update(t, int24(int256(i % 200) - 100), INTERVAL);
        }
    }

    /// @custom:requirement R-ORC-1
    function test_Gas_Update_AccumulateAndOverwriteSnapshot() public {
        vm.cool(address(h));
        uint256 used = h.gasUpdate(t + INTERVAL, 7, INTERVAL);
        emit log_named_uint("update, accumulate + snapshot overwrite (ring full)", used);
        assertLt(used, 30_000);
    }

    /// @custom:requirement R-ORC-3
    function test_Gas_CumulativeNow() public {
        vm.cool(address(h));
        uint256 used = h.gasCumulativeNow(t + 5, 3);
        emit log_named_uint("cumulativeNow", used);
        assertLt(used, 5000);
    }

    /// @custom:requirement R-ORC-2
    function test_Gas_TwapTick_AnchorWindow_FullRing() public {
        vm.cool(address(h));
        uint256 used = h.gasTwap(t + 5, 86_400, 3);
        emit log_named_uint("twapTick, 24h window, full ring (binary search)", used);
        assertLt(used, 60_000);
    }

    /// @custom:requirement R-ORC-2
    function test_Gas_TwapTick_ShortWindow_FullRing() public {
        vm.cool(address(h));
        uint256 used = h.gasTwap(t + 5, 900, 3);
        emit log_named_uint("twapTick, 15min window, full ring (binary search)", used);
        assertLt(used, 60_000);
    }
}
