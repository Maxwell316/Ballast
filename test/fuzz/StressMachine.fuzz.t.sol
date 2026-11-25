// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StressMachine} from "../../src/libraries/StressMachine.sol";
import {LockState} from "../../src/types/Types.sol";

/// @notice Sequence fuzzing of the stress machine. Two oracles:
/// (1) a differential, table-style reference model written from the SPEC text (not from the implementation);
/// (2) property checks that do not depend on either implementation: legal transitions only, hysteresis, the lock
/// window starts only on CALM -> STRESS, an expired lock never re-arms before CALM, calm requires an unbroken
/// below-exit run of `calmDuration`, and the lock is bounded by `maxStressLock` whatever the deviation does.
contract StressMachineFuzzTest is Test {
    struct Cfg {
        uint32 enter;
        uint32 exit_;
        uint32 calm;
        uint32 maxLock;
    }

    /// @dev Reference state, independent of `StressMachine.Ctx` handling.
    struct Ref {
        uint8 state; // 0 CALM, 1 STRESS, 2 RECOVERING
        uint256 start; // lock window start (0 in CALM)
        uint256 runStart; // first sample of the current below-exit run, 0 if none
        bool expiryFlagged;
    }

    /// @dev Reference transition, written as a decision table over (state, class of dev).
    /// class: 2 = dev >= enter, 1 = exit <= dev < enter, 0 = dev < exit.
    function _ref(Ref memory r, int256 dev, bool warm, uint256 t, Cfg memory k)
        internal
        pure
        returns (Ref memory o, bool expiredNow)
    {
        o = r;
        if (!warm) return (Ref(0, 0, 0, false), false);
        uint8 cls = dev >= int256(uint256(k.enter)) ? 2 : (dev < int256(uint256(k.exit_)) ? 0 : 1);
        if (r.state == 0) {
            o.runStart = 0;
            if (cls == 2) {
                o.state = 1;
                o.start = t;
                o.expiryFlagged = false;
            }
        } else if (r.state == 1) {
            if (cls == 0) {
                o.state = 2;
                o.runStart = t;
            } else {
                o.runStart = 0;
            }
        } else {
            if (cls == 2) {
                o.state = 1;
                o.runStart = 0;
            } else if (cls == 1) {
                o.runStart = 0;
            } else if (r.runStart == 0) {
                o.runStart = t;
            } else if (t >= r.runStart + k.calm) {
                o.state = 0;
            }
        }
        if (o.state == 0) {
            o.start = 0;
            o.runStart = 0;
            o.expiryFlagged = false;
        } else if (!o.expiryFlagged && t >= o.start + k.maxLock) {
            o.expiryFlagged = true;
            expiredNow = true;
        }
    }

    function _cfg(uint16 a, uint16 b, uint16 c, uint32 d) internal pure returns (Cfg memory k) {
        k.enter = uint32(bound(a, 50, 3000));
        k.exit_ = uint32(bound(b, 1, k.enter - 1));
        k.calm = uint32(bound(c, 1, 7200));
        k.maxLock = uint32(bound(d, 0, 200_000));
    }

    function _dev(uint256 x, Cfg memory k) internal pure returns (int256) {
        uint256 pick = x % 6;
        if (pick == 0) return int256(uint256(k.enter)); // exactly enter
        if (pick == 1) return int256(uint256(k.exit_)) - 1; // just below exit
        if (pick == 2) return int256(uint256(k.exit_)); // exactly exit (not below)
        if (pick == 3) return int256(uint256(k.enter)) - 1; // just below enter
        if (pick == 4) return int256(x >> 8) % 10_000 - 5000;
        return int256(uint256(k.enter) + (x >> 8) % 5000);
    }

    // ─── Sequence state (storage, to keep the stack shallow) ───
    Cfg internal k;
    StressMachine.Ctx internal c;
    LockState internal s;
    Ref internal r;
    uint256 internal episodeStart; // ground-truth start of the current episode
    bool internal lockWasExpired; // ground truth: expiry observed in this episode
    uint256 internal expiryFlags; // expiry flags in this episode
    uint256 internal runStart; // ground-truth below-exit run, counted while a non-CALM state is evaluated

    function _step(uint256 t, int256 dev, bool warm) internal {
        c.nowTs = uint40(t);
        LockState prev = s;
        StressMachine.Ctx memory prevCtx = c;
        bool expired;
        (LockState ns, StressMachine.Ctx memory nc, bool e) =
            StressMachine.next(s, dev, warm, prevCtx);
        s = ns;
        c = nc;
        expired = e;
        bool refExpired;
        (r, refExpired) = _ref(r, dev, warm, t, k);

        // (1) Differential against the reference model.
        assertEq(uint8(s), r.state, "state matches reference");
        assertEq(c.stressStartedAt, r.start, "start matches reference");
        assertEq(c.belowExitSince, r.runStart, "calm run matches reference");
        assertEq(c.lockExpiryRecorded, r.expiryFlagged, "expiry flag matches reference");
        assertEq(expired, refExpired, "expiry event matches reference");

        _properties(prev, prevCtx, dev, warm, t, expired);
    }

    function _properties(
        LockState prev,
        StressMachine.Ctx memory prevCtx,
        int256 dev,
        bool warm,
        uint256 t,
        bool expired
    ) internal {
        // Legal transitions only.
        if (prev == LockState.CALM) assertTrue(s == LockState.CALM || s == LockState.STRESS);
        if (prev == LockState.STRESS) {
            assertTrue(s == LockState.STRESS || s == LockState.RECOVERING);
        }
        // CALM -> STRESS only when warm and dev >= enter; it starts the window now.
        if (prev == LockState.CALM && s == LockState.STRESS) {
            assertTrue(warm && dev >= int256(uint256(k.enter)));
            assertEq(c.stressStartedAt, t);
            episodeStart = t;
            lockWasExpired = false;
            expiryFlags = 0;
        }
        // The window start never changes except on CALM -> STRESS (cleared on CALM).
        if (prev != LockState.CALM && s != LockState.CALM) {
            assertEq(c.stressStartedAt, prevCtx.stressStartedAt, "start only set on CALM -> STRESS");
            assertEq(c.stressStartedAt, episodeStart);
        }
        if (s == LockState.CALM) assertEq(c.stressStartedAt, 0);
        // Hysteresis: STRESS -> RECOVERING needs dev < exit.
        if (prev == LockState.STRESS && s == LockState.RECOVERING) {
            assertLt(dev, int256(uint256(k.exit_)));
        }
        // Ground-truth below-exit run.
        if (prev != LockState.CALM && dev < int256(uint256(k.exit_)) && warm) {
            if (runStart == 0) runStart = t;
        } else {
            runStart = 0;
        }
        // RECOVERING -> CALM needs an unbroken below-exit run of at least calmDuration ending now.
        if (prev == LockState.RECOVERING && s == LockState.CALM) {
            assertLt(dev, int256(uint256(k.exit_)));
            assertTrue(runStart != 0 && t >= runStart + k.calm, "calm run long enough");
        }
        if (s == LockState.CALM) runStart = 0;
        // Lock bound (G-3): active only before start + maxLock; after that never active until CALM.
        if (s != LockState.CALM) {
            bool active = StressMachine.lockActive(s, c);
            assertEq(active, t < episodeStart + k.maxLock);
            if (t >= episodeStart + k.maxLock) {
                lockWasExpired = true;
                assertFalse(active, "expired lock must not be active");
            }
            if (lockWasExpired) assertFalse(active, "no re-arm before CALM");
        } else {
            assertFalse(StressMachine.lockActive(s, c));
            lockWasExpired = false;
        }
        // Expiry event: at most once per episode, only at or after start + maxLock, only in a non-CALM state.
        if (expired) {
            expiryFlags++;
            assertTrue(s != LockState.CALM && t >= c.stressStartedAt + k.maxLock);
            assertLe(expiryFlags, 1, "LockExpired emitted at most once per episode");
        }
        // Not warm: always CALM with cleared timers.
        if (!warm) {
            assertEq(uint8(s), uint8(LockState.CALM));
            assertEq(c.belowExitSince, 0);
        }
    }

    /// forge-config: default.fuzz.runs = 400
    /// forge-config: ci.fuzz.runs = 4000
    /// @custom:requirement R-STR-1 R-STR-2 R-STR-3 R-STR-4 R-STR-5 R-STR-6
    /// @custom:invariant INV-6 INV-12
    function testFuzz_Sequence_MatchesReferenceAndSatisfiesProperties(
        uint256 seed,
        uint16 enterRaw,
        uint16 exitRaw,
        uint16 calmRaw,
        uint32 lockRaw,
        uint8 stepsRaw
    ) public {
        k = _cfg(enterRaw, exitRaw, calmRaw, lockRaw);
        c.enterTicks = k.enter;
        c.exitTicks = k.exit_;
        c.calmDuration = k.calm;
        c.maxStressLock = k.maxLock;
        s = LockState.CALM;

        // Realistic timestamps: a large, fuzzed base so start-time bugs cannot hide behind small clock values.
        uint256 t = 1 + uint256(keccak256(abi.encode(seed, "base"))) % 2_000_000_000;
        uint256 warmAt = uint256(keccak256(abi.encode(seed, "warm"))) % 5; // warm from step `warmAt` on (monotonic)
        uint256 steps = bound(stepsRaw, 1, 120);
        for (uint256 i; i < steps; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            t += x % (k.calm / 2 + 2 + uint256(k.maxLock) / 40); // varied gaps, sometimes zero
            _step(t, _dev(x >> 16, k), i >= warmAt);
        }
    }

    /// @notice G-3 stated directly: whatever the deviation does, from the moment of CALM -> STRESS the lock is
    /// inactive from `start + maxLock` on, until the machine has been CALM.
    /// forge-config: default.fuzz.runs = 400
    /// forge-config: ci.fuzz.runs = 4000
    /// @custom:requirement R-STR-4 R-STR-5
    /// @custom:invariant INV-6 INV-12
    function testFuzz_LockIsBounded_UnderAdversarialDeviation(
        uint256 seed,
        uint32 lockRaw,
        uint16 calmRaw
    ) public pure {
        Cfg memory k = Cfg(
            300, 150, uint32(bound(calmRaw, 300, 7200)), uint32(bound(lockRaw, 600, 100_000))
        );
        StressMachine.Ctx memory c;
        c.enterTicks = k.enter;
        c.exitTicks = k.exit_;
        c.calmDuration = k.calm;
        c.maxStressLock = k.maxLock;
        LockState s = LockState.CALM;
        uint256 t = 1_700_000_000 + seed % 100_000_000;
        // Enter stress.
        c.nowTs = uint40(t);
        (s, c,) = StressMachine.next(s, 1000, true, c);
        assertEq(uint8(s), uint8(LockState.STRESS));
        uint256 start = t;
        // An adversary alternates deviations to keep the machine out of CALM as long as it can.
        for (uint256 i; i < 200; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            t += 1 + x % (k.calm / 3);
            // Never let a below-exit run reach calmDuration: break it with a mid or high sample frequently.
            int256 dev = (x >> 8) % 3 == 0 ? int256(0) : int256(200 + (x >> 16) % 400);
            c.nowTs = uint40(t);
            (s, c,) = StressMachine.next(s, dev, true, c);
            if (s == LockState.CALM) return; // the adversary lost: a new episode would need a fresh CALM -> STRESS
            if (t >= start + k.maxLock) {
                assertFalse(StressMachine.lockActive(s, c), "lock never outlasts maxStressLock");
            }
        }
    }
}
