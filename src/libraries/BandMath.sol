// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BPS_DENOMINATOR} from "../types/Constants.sol";

/// @title BandMath
/// @notice Conversions between basis points of price impact and ticks, and band edges in the liquidation
/// direction. Formulas, rounding directions and the epsilon rule are specified in docs/MATH.md §2 (ADR-035).
/// @dev For a fractional fall `x = bps / 10_000` the tick distance is `ln(1 / (1 - x)) / ln(1.0001)`; it is the
/// same for both collateral directions (the price factor is 1/(1-x) either way).
library BandMath {
    /// @dev ln(1.0001) in WAD, floored (computed off-chain; tools/gen_band_ref.py). Relative error below 1e-14.
    int256 internal constant LN_1_0001_WAD = 99995000333308;
    /// @dev Conservative bias subtracted from the raw tick distance, in WAD (1e-9 ticks). It must exceed the
    /// worst-case fixed-point error of the computation so the biased value never exceeds the exact value.
    int256 internal constant EPS_WAD = 1e9;
    /// @dev Largest possible tick distance between MIN_TICK and MAX_TICK. Used for bps >= 10_000 (price to zero).
    uint24 internal constant MAX_TICK_SPAN =
        uint24(uint256(int256(TickMath.MAX_TICK) - int256(TickMath.MIN_TICK)));

    int256 private constant WAD = 1e18;

    /// @notice Tick distance of a price fall of `bps`, in WAD, minus the conservative bias (`EPS_WAD`).
    /// @dev Never exceeds the exact value (MATH §2). `bps == 0` returns 0; `bps >= 10_000` is not representable and
    /// callers must use `bpsToTicksDown`, which caps it.
    /// @param bps Price impact in basis points, `0 < bps < 10_000`.
    /// @return deltaWad `Δ(x)` in ticks x 1e18, rounded down, minus `EPS_WAD`, floored at 0.
    /// @custom:requirement R-STR-8
    function bpsToTicksWad(uint16 bps) internal pure returns (uint256 deltaWad) {
        if (bps == 0) return 0;
        // ratio = 10_000 / (10_000 - bps) in WAD, rounded down so ln is never overstated by this step.
        // SAFETY: bps < 10_000 (checked by callers), so the denominator is positive; bps fits uint16.
        int256 ratio =
            (WAD * int256(BPS_DENOMINATOR)) / (int256(BPS_DENOMINATOR) - int256(uint256(bps)));
        int256 raw = (FixedPointMathLib.lnWad(ratio) * WAD) / LN_1_0001_WAD;
        raw -= EPS_WAD;
        // SAFETY: lnWad(ratio >= 1e18) >= 0, so raw >= 0 before the bias; the floor below restores non-negativity.
        deltaWad = raw > 0 ? uint256(raw) : 0;
    }

    /// @notice Conservative tick distance for a price impact of `bps`: the band is never wider than the exact one.
    /// @dev `floor(bpsToTicksWad / 1e18)`. For `bps >= 10_000` returns `MAX_TICK_SPAN`.
    /// @param bps Price impact in basis points.
    /// @return ticks Tick distance, rounded down (narrower band, less depth).
    /// @custom:requirement R-VIEW-2
    function bpsToTicksDown(uint16 bps) internal pure returns (uint24 ticks) {
        if (bps >= BPS_DENOMINATOR) return MAX_TICK_SPAN;
        // SAFETY: bps < 10_000 gives at most ~92_108 ticks, which fits uint24.
        ticks = uint24(bpsToTicksWad(bps) / uint256(WAD));
    }

    /// @notice Tick distance for a price impact of `bps`, rounded to nearest (used for stress thresholds).
    /// @dev Neutral rounding: bias in either direction is a policy choice (MATH §2). `bps >= 10_000` returns
    /// `MAX_TICK_SPAN`.
    /// @param bps Price impact in basis points.
    /// @return ticks Tick distance, rounded half up.
    /// @custom:requirement R-STR-8
    function bpsToTicksNearest(uint16 bps) internal pure returns (uint24 ticks) {
        if (bps >= BPS_DENOMINATOR) return MAX_TICK_SPAN;
        if (bps == 0) return 0;
        int256 ratio =
            (WAD * int256(BPS_DENOMINATOR)) / (int256(BPS_DENOMINATOR) - int256(uint256(bps)));
        int256 raw = (FixedPointMathLib.lnWad(ratio) * WAD) / LN_1_0001_WAD;
        // SAFETY: raw >= 0 and < ~92_108e18; adding 0.5e18 cannot overflow; result fits uint24.
        ticks = uint24(uint256(raw + WAD / 2) / uint256(WAD));
    }

    /// @notice Band edges in the liquidation direction for an anchor (or spot) tick.
    /// @dev Collateral is currency0: liquidations push the tick down, so the band is `[far, near]` with
    /// `far = anchor - bandTicks`. Collateral is currency1: the band is `[near, far]` with
    /// `far = anchor + bandTicks`. `far` is clamped to `[MIN_TICK, MAX_TICK]`.
    /// @param anchorTick The tick the band starts from.
    /// @param collateralIs0 Whether the collateral is currency0.
    /// @param bandTicks Band length in ticks.
    /// @return nearTick The edge at the anchor.
    /// @return farTick The edge `bandTicks` away in the liquidation direction.
    /// @custom:requirement R-VIEW-2
    function bandEdges(int24 anchorTick, bool collateralIs0, uint24 bandTicks)
        internal
        pure
        returns (int24 nearTick, int24 farTick)
    {
        nearTick = anchorTick;
        // Widen to int256 so the addition cannot overflow int24 before clamping.
        int256 far = collateralIs0
            ? int256(anchorTick) - int256(uint256(bandTicks))
            : int256(anchorTick) + int256(uint256(bandTicks));
        if (far < TickMath.MIN_TICK) far = TickMath.MIN_TICK;
        if (far > TickMath.MAX_TICK) far = TickMath.MAX_TICK;
        // SAFETY: clamped to [MIN_TICK, MAX_TICK], which fits int24.
        farTick = int24(far);
    }
}
