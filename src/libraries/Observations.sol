// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/// @title Observations
/// @notice Tick-cumulative oracle with v3-style semantics, our own implementation (ADR-011, ADR-013, ADR-036).
/// @dev Two layers. (1) A running accumulator `State.cumulative`, updated on every swap with a new timestamp, so the
/// current cumulative and every value at an update time are exact. (2) A ring buffer of snapshots of that accumulator,
/// written at most once per `minInterval`. Interpolating between two snapshots is exact only if no swap fell between
/// them; the error bound is `minInterval * maxTickSwing` on the cumulative (docs/MATH.md §4).
///
/// Gas design (ADR-036): `update` is O(1) (one packed state slot and at most one snapshot write). The binary search
/// runs only in `cumulativeAt`/`twapTick`, which the hook calls from its stress-evaluation path (at most once per
/// observation interval) and from views. The ring grows lazily by push until `cardinality` entries exist, then wraps,
/// so there is no up-front storage cost.
library Observations {
    /// @notice A snapshot of the running accumulator.
    struct Observation {
        uint40 timestamp;
        int56 tickCumulative;
    }

    /// @notice Running accumulator and ring bookkeeping, packed into one slot (192 bits).
    /// @dev `index` is the position of the newest snapshot. `lastTick` is the pre-swap tick read at the last
    /// accumulator update; it is retained for diagnostics and invariant checks (INV-11) and is not used by the maths.
    struct State {
        uint16 index;
        uint16 cardinality;
        uint40 lastSwapTs;
        int24 lastTick;
        int56 cumulative;
        uint40 lastSnapshotTs;
    }

    /// @notice A query or update used a time earlier than the last update.
    error TimeRegression(uint40 nowTs, uint40 lastSwapTs);
    /// @notice A TWAP window of zero seconds was requested.
    error ZeroWindow();
    /// @notice The state was initialized twice or with zero cardinality.
    error InvalidInitialization();

    /// @notice Seeds snapshot 0 and the accumulator (R-POOL-4).
    /// @param self The ring storage (must be empty).
    /// @param s The state storage.
    /// @param time Current timestamp.
    /// @param tick Initial pool tick.
    /// @param cardinality Fixed ring size (`Config.observationCardinality`).
    /// @custom:requirement R-POOL-4
    function initialize(
        Observation[] storage self,
        State storage s,
        uint40 time,
        int24 tick,
        uint16 cardinality
    ) internal {
        if (cardinality == 0 || self.length != 0) revert InvalidInitialization();
        self.push(Observation({timestamp: time, tickCumulative: 0}));
        s.index = 0;
        s.cardinality = cardinality;
        s.lastSwapTs = time;
        s.lastTick = tick;
        s.cumulative = 0;
        s.lastSnapshotTs = time;
    }

    /// @notice Advances the accumulator for a swap and, if due, writes a snapshot.
    /// @dev Does nothing if `nowTs == lastSwapTs` (accumulate once per timestamp: a swap and its reversal in one block
    /// carry zero weight, R-ORC-1). Otherwise `cumulative += preSwapTick * (nowTs - lastSwapTs)`, then, only if
    /// `nowTs - lastSnapshotTs >= minInterval`, appends a snapshot. The accumulator is never skipped.
    /// @param self The ring storage.
    /// @param s The state storage.
    /// @param nowTs Current timestamp (`block.timestamp`).
    /// @param preSwapTick The PoolManager's `slot0.tick` read before the swap executes.
    /// @param minInterval Minimum seconds between snapshots.
    /// @return snapshotted Whether a snapshot was written.
    /// @custom:requirement R-ORC-1
    /// @custom:invariant INV-11
    function update(
        Observation[] storage self,
        State storage s,
        uint40 nowTs,
        int24 preSwapTick,
        uint32 minInterval
    ) internal returns (bool snapshotted) {
        State memory st = s;
        if (nowTs == st.lastSwapTs) return false;
        if (nowTs < st.lastSwapTs) revert TimeRegression(nowTs, st.lastSwapTs);

        // SAFETY: nowTs > lastSwapTs, both uint40, so the difference is below 2^40; |tick| < 2^20, so the product is
        // below 2^60 and fits int256; SafeCastLib reverts if the running sum would leave int56.
        int256 delta = int256(preSwapTick) * int256(uint256(nowTs - st.lastSwapTs));
        int256 newCumulative = int256(st.cumulative) + delta;
        st.cumulative = SafeCastLib.toInt56(newCumulative);
        st.lastSwapTs = nowTs;
        st.lastTick = preSwapTick;

        if (nowTs - st.lastSnapshotTs >= minInterval) {
            uint256 len = self.length;
            Observation memory o = Observation({timestamp: nowTs, tickCumulative: st.cumulative});
            if (len < st.cardinality) {
                self.push(o);
                // SAFETY: len < cardinality <= type(uint16).max, so len fits uint16.
                st.index = uint16(len);
            } else {
                // SAFETY: (index + 1) % cardinality < cardinality <= type(uint16).max.
                st.index = uint16((uint256(st.index) + 1) % st.cardinality);
                self[st.index] = o;
            }
            st.lastSnapshotTs = nowTs;
            snapshotted = true;
        }
        s.index = st.index;
        s.lastSwapTs = st.lastSwapTs;
        s.lastTick = st.lastTick;
        s.cumulative = st.cumulative;
        s.lastSnapshotTs = st.lastSnapshotTs;
    }

    /// @notice The exact cumulative at `nowTs`: `cumulative + currentTick * (nowTs - lastSwapTs)`.
    /// @dev Exact because the tick has not changed since the last swap (R-ORC-3).
    /// @param s The state storage.
    /// @param nowTs Current timestamp.
    /// @param currentTick The PoolManager's current tick.
    /// @custom:requirement R-ORC-3
    function cumulativeNow(State storage s, uint40 nowTs, int24 currentTick)
        internal
        view
        returns (int56)
    {
        return _extend(s.cumulative, s.lastSwapTs, nowTs, currentTick);
    }

    /// @notice The cumulative at `nowTs - secondsAgo`.
    /// @dev Exact for targets at or after the last update and at snapshot times; linearly interpolated (rounded
    /// toward negative infinity) between snapshots otherwise. If the target is older than the oldest retained
    /// snapshot, returns that snapshot's cumulative with `warm = false` (R-ORC-4).
    /// @param self The ring storage.
    /// @param s The state storage.
    /// @param nowTs Current timestamp.
    /// @param secondsAgo How far back to look.
    /// @param currentTick The PoolManager's current tick.
    /// @return cumulative The cumulative (see above).
    /// @return warm Whether history covers the target.
    /// @custom:requirement R-ORC-3 R-ORC-4
    function cumulativeAt(
        Observation[] storage self,
        State storage s,
        uint40 nowTs,
        uint32 secondsAgo,
        int24 currentTick
    ) internal view returns (int56 cumulative, bool warm) {
        State memory st = s;
        if (nowTs < st.lastSwapTs) revert TimeRegression(nowTs, st.lastSwapTs);
        if (secondsAgo > nowTs) {
            // The target precedes the epoch: older than any snapshot.
            return (self[_physical(self.length, st, 0)].tickCumulative, false);
        }
        // SAFETY: secondsAgo <= nowTs checked above.
        uint256 target = uint256(nowTs) - secondsAgo;
        if (target >= st.lastSwapTs) {
            // SAFETY: target <= nowTs < 2^40, so the cast is exact.
            // forge-lint: disable-next-line(unsafe-typecast)
            return (_extend(st.cumulative, st.lastSwapTs, uint40(target), currentTick), true);
        }

        return _lookup(self, st, target);
    }

    /// @dev `cumulativeAt` for a target strictly before the last update: search the ring and interpolate.
    function _lookup(Observation[] storage self, State memory st, uint256 target)
        private
        view
        returns (int56 cumulative, bool warm)
    {
        uint256 len = self.length;
        Observation memory oldest = self[_physical(len, st, 0)];
        if (target < oldest.timestamp) return (oldest.tickCumulative, false);

        uint256 lo = _search(self, st, len, target);
        Observation memory a = self[_physical(len, st, lo)];
        if (a.timestamp == target) return (a.tickCumulative, true);

        if (lo < len - 1) {
            Observation memory b = self[_physical(len, st, lo + 1)];
            return (_interpolate(a, b.timestamp, b.tickCumulative, target), true);
        }
        // `a` is the newest snapshot and target lies before the last update: bracket with the accumulator.
        return (_interpolate(a, st.lastSwapTs, st.cumulative, target), true);
    }

    /// @dev Greatest logical index whose timestamp is `<= target`. Precondition: the oldest timestamp is `<= target`.
    function _search(Observation[] storage self, State memory st, uint256 len, uint256 target)
        private
        view
        returns (uint256 lo)
    {
        uint256 hi = len - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (self[_physical(len, st, mid)].timestamp <= target) lo = mid;
            else hi = mid - 1;
        }
    }

    /// @dev Linear interpolation of the cumulative between `a` and `(bTs, bCum)`, rounded toward negative infinity.
    function _interpolate(Observation memory a, uint256 bTs, int256 bCum, uint256 target)
        private
        pure
        returns (int56)
    {
        // SAFETY: a.timestamp < target < bTs, all below 2^40; the cumulative difference is below 2^57; the product
        // is below 2^97 and fits int256. The denominator is positive.
        int256 num = (bCum - int256(a.tickCumulative)) * int256(target - a.timestamp);
        int256 den = int256(bTs - a.timestamp);
        // SAFETY: the interpolated value lies between the two cumulatives, which are int56.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int56(int256(a.tickCumulative) + _floorDiv(num, den));
    }

    /// @notice Time-weighted average tick over `window` seconds, rounded toward negative infinity (R-ORC-2).
    /// @dev If history does not cover the window (`warm == false`), the average is taken over the actual elapsed time
    /// since the oldest snapshot (R-ORC-6), or is the current tick if that is zero.
    /// @param self The ring storage.
    /// @param s The state storage.
    /// @param nowTs Current timestamp.
    /// @param window Window in seconds (non-zero).
    /// @param currentTick The PoolManager's current tick.
    /// @return tick The TWAP tick.
    /// @return warm Whether the window is fully covered.
    /// @custom:requirement R-ORC-2 R-ORC-4 R-ORC-6
    function twapTick(
        Observation[] storage self,
        State storage s,
        uint40 nowTs,
        uint32 window,
        int24 currentTick
    ) internal view returns (int24 tick, bool warm) {
        if (window == 0) revert ZeroWindow();
        int256 nowCum = cumulativeNow(s, nowTs, currentTick);
        int56 pastCum;
        (pastCum, warm) = cumulativeAt(self, s, nowTs, window, currentTick);
        if (warm) {
            // SAFETY: |cumulative difference| / window is a weighted average of ticks, so it lies in the int24 range.
            // forge-lint: disable-next-line(unsafe-typecast)
            tick = int24(_floorDiv(nowCum - pastCum, int256(uint256(window))));
        } else {
            State memory st = s;
            uint256 oldestTs = self[_physical(self.length, st, 0)].timestamp;
            if (nowTs <= oldestTs) return (currentTick, false);
            // forge-lint: disable-next-line(unsafe-typecast)
            tick = int24(_floorDiv(nowCum - pastCum, int256(uint256(nowTs) - oldestTs)));
        }
    }

    /// @notice Whether the oldest retained snapshot is at or before `nowTs - window`.
    /// @dev Monotonic for `window <= anchorWindow` when cardinality is at least `ceil(anchorWindow / minInterval) + 1`
    /// (R-ORC-5, R-ORC-7, proof in MATH §4).
    /// @custom:requirement R-ORC-4 R-ORC-7
    /// @custom:invariant INV-15
    function isWarm(Observation[] storage self, State storage s, uint40 nowTs, uint32 window)
        internal
        view
        returns (bool)
    {
        State memory st = s;
        return uint256(self[_physical(self.length, st, 0)].timestamp) + window <= nowTs;
    }

    /// @dev Physical array index of the `logical`-th snapshot, oldest first.
    function _physical(uint256 len, State memory st, uint256 logical)
        private
        pure
        returns (uint256)
    {
        // While the ring is filling, snapshots are in order from index 0. Once full, the oldest follows `index`.
        if (len < st.cardinality) return logical;
        return (uint256(st.index) + 1 + logical) % len;
    }

    /// @dev `base + tick * (to - from)`, reverting if the result leaves int56.
    function _extend(int56 base, uint40 from, uint40 to, int24 tick) private pure returns (int56) {
        if (to < from) revert TimeRegression(to, from);
        // SAFETY: to >= from (callers guarantee), difference below 2^40, |tick| < 2^20, product below 2^60.
        int256 v = int256(base) + int256(tick) * int256(uint256(to - from));
        return SafeCastLib.toInt56(v);
    }

    /// @dev Division rounding toward negative infinity. `den` must be positive.
    function _floorDiv(int256 num, int256 den) private pure returns (int256 q) {
        q = num / den;
        if (num % den != 0 && num < 0) q -= 1;
    }
}
