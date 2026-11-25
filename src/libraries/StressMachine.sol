// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LockState} from "../types/Types.sol";

/// @title StressMachine
/// @notice Pure transition function of the stress lock: CALM, STRESS, RECOVERING (docs/SPEC.md §6, ADR-019, ADR-033).
/// @dev All logic lives in `next`; the hook only supplies inputs and stores the result. Views call it as a preview.
///
/// Deviation: `dev = collateralIs0 ? (A - S) : (S - A)` in ticks, positive when the short TWAP is displaced in the
/// liquidation direction. Thresholds `enterTicks > exitTicks` give hysteresis.
///
/// ```
///   CALM ──dev ≥ enter (warm)──▶ STRESS ──dev < exit──▶ RECOVERING ──dev < exit for calmDuration──▶ CALM
///                                  ▲                        │
///                                  └──────dev ≥ enter───────┘
/// ```
/// `stressStartedAt` is set only on CALM → STRESS, so a relapse cannot extend the lock (G-3, D-6): the lock is
/// active while `state != CALM && now < stressStartedAt + maxStressLock`, and an expired lock cannot become active
/// again without an intervening CALM. Calm-period continuity is checked at evaluation points only (R-STR-9).
library StressMachine {
    /// @notice Inputs and carried timers of one evaluation. Absolute times are uint40, durations/thresholds uint32.
    struct Ctx {
        uint40 nowTs; // evaluation time
        uint40 stressStartedAt; // set on CALM -> STRESS only; 0 in CALM
        uint40 belowExitSince; // start of the current below-exit run; 0 if none
        uint32 enterTicks; // dev >= enterTicks enters STRESS
        uint32 exitTicks; // dev < exitTicks counts toward calm; exitTicks < enterTicks
        uint32 calmDuration; // seconds below exit before CALM
        uint32 maxStressLock; // hard cap on the lock per episode
        bool lockExpiryRecorded; // set when expiry is first evaluated in a non-CALM state; cleared on CALM
    }

    /// @notice One evaluation of the machine.
    /// @dev Total and pure. If `warm` is false the result is CALM with cleared timers (R-STR-6); this also releases a
    /// non-CALM state handed in with `warm == false`, which is unreachable because warm is monotonic (R-ORC-7), so a
    /// bad input can never trap depositors.
    /// @param s Current state.
    /// @param dev Signed deviation in ticks (see library docs).
    /// @param warm Whether the anchor window is covered by history.
    /// @param c Context; `c.nowTs` is the evaluation time.
    /// @return ns The new state.
    /// @return nc The updated context.
    /// @return lockJustExpired True when this call first recorded the lock expiry (emit `LockExpired` once).
    /// @custom:requirement R-STR-1 R-STR-2 R-STR-3 R-STR-5 R-STR-6
    /// @custom:invariant INV-12
    function next(LockState s, int256 dev, bool warm, Ctx memory c)
        internal
        pure
        returns (LockState ns, Ctx memory nc, bool lockJustExpired)
    {
        // Explicit copy: assigning a memory struct only aliases it, which would mutate the caller's context in place.
        nc = Ctx({
            nowTs: c.nowTs,
            stressStartedAt: c.stressStartedAt,
            belowExitSince: c.belowExitSince,
            enterTicks: c.enterTicks,
            exitTicks: c.exitTicks,
            calmDuration: c.calmDuration,
            maxStressLock: c.maxStressLock,
            lockExpiryRecorded: c.lockExpiryRecorded
        });
        if (!warm) {
            nc.stressStartedAt = 0;
            nc.belowExitSince = 0;
            nc.lockExpiryRecorded = false;
            return (LockState.CALM, nc, false);
        }

        ns = s;
        bool enter = dev >= int256(uint256(c.enterTicks));
        bool belowExit = dev < int256(uint256(c.exitTicks));

        if (s == LockState.CALM) {
            nc.belowExitSince = 0;
            if (enter) {
                ns = LockState.STRESS;
                nc.stressStartedAt = c.nowTs; // the only place the lock window starts (R-STR-1)
            }
        } else if (s == LockState.STRESS) {
            if (enter) {
                nc.belowExitSince = 0;
            } else if (belowExit) {
                ns = LockState.RECOVERING;
                nc.belowExitSince = c.nowTs;
            } else {
                nc.belowExitSince = 0; // between the thresholds: stay STRESS
            }
        } else {
            // RECOVERING
            if (enter) {
                ns = LockState.STRESS; // relapse: stressStartedAt is NOT reset (R-STR-2)
                nc.belowExitSince = 0;
            } else if (belowExit) {
                if (c.belowExitSince == 0) {
                    nc.belowExitSince = c.nowTs;
                } else if (uint256(c.nowTs) >= uint256(c.belowExitSince) + c.calmDuration) {
                    ns = LockState.CALM; // calm held for calmDuration (R-STR-3)
                }
            } else {
                nc.belowExitSince = 0; // calm period interrupted
            }
        }

        if (ns == LockState.CALM) {
            nc.stressStartedAt = 0;
            nc.belowExitSince = 0;
            nc.lockExpiryRecorded = false;
        } else if (
            !nc.lockExpiryRecorded
                && uint256(c.nowTs) >= uint256(nc.stressStartedAt) + c.maxStressLock
        ) {
            nc.lockExpiryRecorded = true;
            lockJustExpired = true; // first evaluation at or after expiry (R-STR-5)
        }
    }

    /// @notice Whether the lock is active: `state != CALM && now < stressStartedAt + maxStressLock` (R-STR-4).
    /// @param s Current state.
    /// @param c Context (uses `nowTs`, `stressStartedAt`, `maxStressLock`).
    /// @custom:requirement R-STR-4
    /// @custom:invariant INV-6
    function lockActive(LockState s, Ctx memory c) internal pure returns (bool) {
        return
            s != LockState.CALM && uint256(c.nowTs) < uint256(c.stressStartedAt) + c.maxStressLock;
    }

    /// @notice When the current lock ends, or 0 if it is not active (R-VIEW-3).
    function lockedUntil(LockState s, Ctx memory c) internal pure returns (uint256) {
        return lockActive(s, c) ? uint256(c.stressStartedAt) + c.maxStressLock : 0;
    }
}
