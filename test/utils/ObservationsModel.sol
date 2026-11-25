// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Naive full-history reference for `Observations`: it records every tick change and computes the exact
/// cumulative at any time by summing segments. Test-only; deliberately simple and unoptimized.
contract ObservationsModel {
    struct Seg {
        uint256 start;
        int256 tick;
    }

    Seg[] internal segs;

    function init(uint256 t0, int24 tick0) external {
        segs.push(Seg(t0, tick0));
    }

    /// @notice A swap at time `t` changes the tick to `newTick` from `t` on.
    function swap(uint256 t, int24 newTick) external {
        segs.push(Seg(t, newTick));
    }

    function currentTick() external view returns (int24) {
        return int24(segs[segs.length - 1].tick);
    }

    function lastTime() external view returns (uint256) {
        return segs[segs.length - 1].start;
    }

    /// @notice Exact tick cumulative at time `t` (`t >= t0`).
    function cumulativeAt(uint256 t) public view returns (int256 total) {
        for (uint256 i; i < segs.length; ++i) {
            if (segs[i].start >= t) break;
            uint256 end = i + 1 < segs.length ? segs[i + 1].start : type(uint256).max;
            uint256 upto = end < t ? end : t;
            total += segs[i].tick * int256(upto - segs[i].start);
        }
    }

    /// @notice Largest tick minus smallest tick in force at any time in `[ta, tb]` (including the tick in force at `ta`).
    function swing(uint256 ta, uint256 tb) external view returns (uint256) {
        int256 lo = type(int256).max;
        int256 hi = type(int256).min;
        for (uint256 i; i < segs.length; ++i) {
            uint256 end = i + 1 < segs.length ? segs[i + 1].start : type(uint256).max;
            // Segment is in force at some time in [ta, tb] if start <= tb and end > ta (end is exclusive).
            if (segs[i].start <= tb && end > ta) {
                if (segs[i].tick < lo) lo = segs[i].tick;
                if (segs[i].tick > hi) hi = segs[i].tick;
            }
        }
        return uint256(hi - lo);
    }

    /// @notice Exact TWAP over `[now - window, now]`, rounded toward negative infinity.
    function twap(uint256 nowTs, uint256 window) external view returns (int256) {
        int256 diff = cumulativeAt(nowTs) - cumulativeAt(nowTs - window);
        int256 q = diff / int256(window);
        if (diff % int256(window) != 0 && diff < 0) q -= 1;
        return q;
    }
}
