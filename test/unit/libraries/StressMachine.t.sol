// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StressMachine} from "../../../src/libraries/StressMachine.sol";
import {LockState} from "../../../src/types/Types.sol";

/// @notice Table-driven unit tests of the stress machine (SPEC §6). Thresholds: enter 300, exit 150 ticks;
/// calm 3600 s; max lock 86400 s.
contract StressMachineTest is Test {
    uint32 internal constant ENTER = 300;
    uint32 internal constant EXIT = 150;
    uint32 internal constant CALM_FOR = 3600;
    uint32 internal constant MAX_LOCK = 86_400;

    StressMachine.Ctx internal c;
    LockState internal s;

    function _ctx(uint40 nowTs) internal view returns (StressMachine.Ctx memory x) {
        x = c;
        x.nowTs = nowTs;
        x.enterTicks = ENTER;
        x.exitTicks = EXIT;
        x.calmDuration = CALM_FOR;
        x.maxStressLock = MAX_LOCK;
    }

    /// @dev Evaluate at `nowTs` with `dev`; store the result.
    function _step(uint40 nowTs, int256 dev) internal returns (bool expired) {
        (LockState ns, StressMachine.Ctx memory nc, bool e) =
            StressMachine.next(s, dev, true, _ctx(nowTs));
        s = ns;
        c = nc;
        return e;
    }

    /// @custom:requirement R-STR-1
    function test_CalmToStress_AtEnterThreshold_RecordsStart() public {
        _step(1000, int256(uint256(ENTER)) - 1);
        assertEq(uint8(s), uint8(LockState.CALM), "below enter: stay CALM");
        _step(1060, int256(uint256(ENTER)));
        assertEq(uint8(s), uint8(LockState.STRESS), "dev == enter enters STRESS");
        assertEq(c.stressStartedAt, 1060);
        assertEq(c.belowExitSince, 0);
        assertFalse(c.lockExpiryRecorded);
    }

    /// @notice Realistic (large) timestamps: entering STRESS must not flag an expiry or deactivate the lock. Small
    /// timestamps in the other tests would hide a start-time bug.
    /// @custom:requirement R-STR-1 R-STR-4
    function test_RealisticTimestamps_EntryDoesNotFlagExpiry() public {
        uint40 t0 = 1_800_000_000;
        bool expired = _step(t0, 400);
        assertEq(uint8(s), uint8(LockState.STRESS));
        assertFalse(expired, "entering STRESS is not an expiry");
        assertFalse(c.lockExpiryRecorded);
        assertEq(c.stressStartedAt, t0);
        assertTrue(StressMachine.lockActive(s, _ctx(t0)));
        assertTrue(StressMachine.lockActive(s, _ctx(t0 + MAX_LOCK - 1)));
        assertFalse(StressMachine.lockActive(s, _ctx(t0 + MAX_LOCK)));
        assertTrue(_step(t0 + MAX_LOCK, 400), "expiry flagged at start + max");
    }

    /// @notice `next` must not modify its input context (memory structs alias on assignment).
    /// @custom:requirement R-STR-7
    function test_Next_DoesNotMutateInputContext() public view {
        StressMachine.Ctx memory x = _ctx(1_800_000_000);
        x.stressStartedAt = 7;
        x.belowExitSince = 9;
        (, StressMachine.Ctx memory nc,) = StressMachine.next(LockState.STRESS, 400, true, x);
        assertEq(x.nowTs, 1_800_000_000);
        assertEq(x.stressStartedAt, 7);
        assertEq(x.belowExitSince, 9);
        assertFalse(x.lockExpiryRecorded, "input flag untouched");
        assertTrue(nc.lockExpiryRecorded, "output carries the expiry (start 7 is long ago)");
    }

    /// @custom:requirement R-STR-1
    function test_CalmStaysCalm_ForNegativeAndLargeNegativeDeviation() public {
        _step(10, -1);
        _step(20, type(int256).min);
        assertEq(uint8(s), uint8(LockState.CALM));
        assertEq(c.stressStartedAt, 0);
    }

    /// @custom:requirement R-STR-2
    function test_StressToRecovering_OnlyBelowExit() public {
        _step(100, int256(uint256(ENTER)));
        _step(200, int256(uint256(EXIT))); // == exit: not below, stays STRESS (hysteresis band)
        assertEq(uint8(s), uint8(LockState.STRESS));
        _step(300, int256(uint256(ENTER)) - 1); // between thresholds
        assertEq(uint8(s), uint8(LockState.STRESS));
        _step(400, int256(uint256(EXIT)) - 1);
        assertEq(uint8(s), uint8(LockState.RECOVERING));
        assertEq(c.belowExitSince, 400);
        assertEq(c.stressStartedAt, 100, "start unchanged");
    }

    /// @notice A relapse must not reset `stressStartedAt` (ADR-019): otherwise the lock could be extended forever.
    /// @custom:requirement R-STR-2 R-STR-5
    function test_Relapse_DoesNotResetStressStart() public {
        _step(100, 400);
        _step(200, 0); // RECOVERING
        assertEq(uint8(s), uint8(LockState.RECOVERING));
        _step(300, 400); // relapse
        assertEq(uint8(s), uint8(LockState.STRESS));
        assertEq(c.stressStartedAt, 100, "relapse keeps the original start");
        assertEq(c.belowExitSince, 0);
    }

    /// @custom:requirement R-STR-3
    function test_RecoveringToCalm_AfterCalmDuration_Inclusive() public {
        _step(1000, 400); // STRESS at 1000
        _step(2000, 0); // RECOVERING, belowExitSince = 2000
        _step(2000 + CALM_FOR - 1, 0);
        assertEq(uint8(s), uint8(LockState.RECOVERING), "one second short");
        _step(2000 + CALM_FOR, 0);
        assertEq(uint8(s), uint8(LockState.CALM), "exactly calmDuration: CALM");
        assertEq(c.stressStartedAt, 0);
        assertEq(c.belowExitSince, 0);
        assertFalse(c.lockExpiryRecorded);
    }

    /// @notice An evaluation between the thresholds resets the calm timer (continuity at evaluation points, R-STR-9).
    /// @custom:requirement R-STR-3 R-STR-9
    function test_CalmTimer_ResetByInterveningSample() public {
        _step(1000, 400);
        _step(2000, 0); // RECOVERING, run starts 2000
        _step(3000, 200); // between thresholds: run broken
        assertEq(c.belowExitSince, 0);
        _step(4000, 0); // new run starts at 4000
        assertEq(c.belowExitSince, 4000);
        _step(4000 + CALM_FOR - 1, 0);
        assertEq(uint8(s), uint8(LockState.RECOVERING));
        _step(4000 + CALM_FOR, 0);
        assertEq(uint8(s), uint8(LockState.CALM));
    }

    /// @notice Lock expiry is recorded once, flagged once, and the lock cannot re-arm without an intervening CALM
    /// (D-6, G-3).
    /// @custom:requirement R-STR-4 R-STR-5
    /// @custom:invariant INV-12
    function test_LockExpiry_FlaggedOnce_AndCannotRearm() public {
        _step(1000, 400);
        assertTrue(StressMachine.lockActive(s, _ctx(1000)));
        assertEq(StressMachine.lockedUntil(s, _ctx(1000)), 1000 + MAX_LOCK);
        assertFalse(_step(1000 + MAX_LOCK - 1, 400), "not yet expired");
        assertFalse(c.lockExpiryRecorded);
        assertTrue(_step(1000 + MAX_LOCK, 400), "expiry flagged at start + max");
        assertTrue(c.lockExpiryRecorded);
        assertFalse(StressMachine.lockActive(s, _ctx(1000 + MAX_LOCK)));
        assertEq(StressMachine.lockedUntil(s, _ctx(1000 + MAX_LOCK)), 0);
        assertFalse(_step(1000 + MAX_LOCK + 10, 400), "flagged only once");
        // Relapse after expiry: still STRESS, but the lock does not become active again.
        _step(1000 + MAX_LOCK + 20, 0); // RECOVERING
        _step(1000 + MAX_LOCK + 30, 400); // relapse
        assertEq(uint8(s), uint8(LockState.STRESS));
        assertFalse(
            StressMachine.lockActive(s, _ctx(1000 + MAX_LOCK + 30)), "no re-arm without CALM"
        );
        // Only a return to CALM and a new CALM -> STRESS starts a new window.
        _step(1000 + MAX_LOCK + 40, 0);
        _step(1000 + MAX_LOCK + 40 + CALM_FOR, 0);
        assertEq(uint8(s), uint8(LockState.CALM));
        _step(1000 + MAX_LOCK + 50 + CALM_FOR, 400);
        assertEq(uint8(s), uint8(LockState.STRESS));
        assertTrue(
            StressMachine.lockActive(s, _ctx(1000 + MAX_LOCK + 50 + CALM_FOR)),
            "new episode, new lock"
        );
        assertFalse(c.lockExpiryRecorded, "flag cleared by the new episode");
    }

    /// @custom:requirement R-STR-4
    function test_LockActive_FalseInCalm_AndAtExactExpiry() public view {
        StressMachine.Ctx memory x = _ctx(5000);
        x.stressStartedAt = 1000;
        assertFalse(StressMachine.lockActive(LockState.CALM, x), "CALM never locks");
        x.nowTs = 1000 + MAX_LOCK - 1;
        assertTrue(StressMachine.lockActive(LockState.STRESS, x));
        assertTrue(StressMachine.lockActive(LockState.RECOVERING, x));
        x.nowTs = 1000 + MAX_LOCK;
        assertFalse(StressMachine.lockActive(LockState.STRESS, x), "now == start + max: expired");
    }

    /// @custom:requirement R-STR-4
    function test_ZeroMaxLock_ExpiresImmediately() public {
        StressMachine.Ctx memory x = _ctx(500);
        x.maxStressLock = 0;
        (LockState ns, StressMachine.Ctx memory nc, bool expired) =
            StressMachine.next(LockState.CALM, 400, true, x);
        assertEq(uint8(ns), uint8(LockState.STRESS));
        assertTrue(expired);
        assertTrue(nc.lockExpiryRecorded);
        assertFalse(StressMachine.lockActive(ns, nc));
    }

    /// @custom:requirement R-STR-6
    function test_NotWarm_StaysCalm_EvenAboveEnter() public {
        (LockState ns, StressMachine.Ctx memory nc, bool e) =
            StressMachine.next(LockState.CALM, 10_000, false, _ctx(100));
        assertEq(uint8(ns), uint8(LockState.CALM));
        assertEq(nc.stressStartedAt, 0);
        assertFalse(e);
    }

    /// @notice Defensive: a non-CALM state with `warm == false` (unreachable) is released to CALM with cleared timers.
    /// @custom:requirement R-STR-6
    function test_NotWarm_ReleasesNonCalmState() public {
        StressMachine.Ctx memory x = _ctx(100);
        x.stressStartedAt = 50;
        x.belowExitSince = 70;
        x.lockExpiryRecorded = true;
        LockState[2] memory states = [LockState.STRESS, LockState.RECOVERING];
        for (uint256 i; i < 2; ++i) {
            (LockState ns, StressMachine.Ctx memory nc, bool e) =
                StressMachine.next(states[i], 10_000, false, x);
            assertEq(uint8(ns), uint8(LockState.CALM));
            assertEq(nc.stressStartedAt, 0);
            assertEq(nc.belowExitSince, 0);
            assertFalse(nc.lockExpiryRecorded);
            assertFalse(e);
        }
    }

    /// @custom:requirement R-STR-2
    function test_RecoveringBetweenThresholds_StaysRecovering_WithTimerCleared() public {
        _step(100, 400);
        _step(200, 0);
        _step(300, 200); // between thresholds
        assertEq(uint8(s), uint8(LockState.RECOVERING));
        assertEq(c.belowExitSince, 0);
        // Below exit again with the timer unset starts a fresh run.
        _step(400, 0);
        assertEq(c.belowExitSince, 400);
    }

    /// @custom:requirement R-STR-1
    function test_ExtremeDeviations_DoNotOverflow() public {
        _step(100, type(int256).max);
        assertEq(uint8(s), uint8(LockState.STRESS));
        _step(200, type(int256).min);
        assertEq(uint8(s), uint8(LockState.RECOVERING));
    }
}
