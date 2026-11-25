// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BPS_DENOMINATOR, RATE_SCALE} from "../types/Constants.sol";

/// @title RewardMath
/// @notice Standby reward arithmetic (docs/MATH.md §7, §8). Pure functions; the hook orchestrates.
/// @dev Units: `rate` is quote raw units per collateral raw unit per second, scaled by `RATE_SCALE`. Every
/// division rounds down, so total credited rewards never exceed what the formula allows (INV-8, G-5).
library RewardMath {
    /// @notice A curator fee above 100% was supplied.
    error InvalidBps(uint16 bps);

    /// @notice Seconds of the current accrual interval: `min(now - last, maxInterval)`, or 0 if `now <= last`.
    /// @param nowTs Current timestamp.
    /// @param lastCheckpoint Timestamp of the previous checkpoint.
    /// @param maxAccrualInterval Cap on one interval (`Config.maxAccrualInterval`).
    /// @custom:requirement R-SBY-3
    function accrualInterval(uint256 nowTs, uint256 lastCheckpoint, uint256 maxAccrualInterval)
        internal
        pure
        returns (uint256)
    {
        if (nowTs <= lastCheckpoint) return 0;
        uint256 elapsed = nowTs - lastCheckpoint;
        return elapsed < maxAccrualInterval ? elapsed : maxAccrualInterval;
    }

    /// @notice Conservative eligible depth across an interval: `min(sampleStart, sampleNow, commitment)`.
    /// @dev The depth samples are `min(anchor-based D_v, live depth)` (ADR-025); the commitment caps what is paid.
    /// @custom:requirement R-SBY-3
    /// @custom:invariant INV-8
    function eligible(uint128 sampleStart, uint128 sampleNow, uint128 commitment)
        internal
        pure
        returns (uint128)
    {
        uint128 m = sampleStart < sampleNow ? sampleStart : sampleNow;
        return m < commitment ? m : commitment;
    }

    /// @notice `floor(eligibleDepth * dt * rate / RATE_SCALE)`.
    /// @dev Rounds down. `eligibleDepth * dt < 2^160`, so the first product cannot overflow; the second uses a
    /// 512-bit intermediate. The result is below `2^229` (about 2^228.2 at the extremes) and is capped by the fund balance by the caller.
    /// @param eligibleDepth Eligible collateral depth (raw units).
    /// @param rate Standby rate (quote raw per collateral raw per second, scaled by `RATE_SCALE`).
    /// @param dt Interval length in seconds.
    /// @return reward Quote raw units, rounded down.
    /// @custom:requirement R-SBY-3
    /// @custom:invariant INV-8
    function accrue(uint128 eligibleDepth, uint128 rate, uint32 dt)
        internal
        pure
        returns (uint256 reward)
    {
        // SAFETY: eligibleDepth < 2^128 and dt < 2^32, so the product is below 2^160.
        uint256 depthSeconds = uint256(eligibleDepth) * dt;
        reward = FixedPointMathLib.fullMulDiv(depthSeconds, rate, RATE_SCALE);
    }

    /// @notice Caps a reward by the fund balance.
    /// @custom:requirement R-SBY-3
    /// @custom:invariant INV-8
    function capToFund(uint256 reward, uint256 fundBalance) internal pure returns (uint256) {
        return reward < fundBalance ? reward : fundBalance;
    }

    /// @notice Splits a credit into the curator's cut and the remainder for depositors.
    /// @dev `toCurator = floor(amount * feeBps / 10_000)`; rounding favours depositors by at most one unit
    /// (MATH §8). Reverts `InvalidBps` if `feeBps > 10_000`.
    /// @param amount Reward or crystallized fee amount.
    /// @param feeBps Curator fee in basis points.
    /// @return toCurator The curator's share, rounded down.
    /// @return toIdle The depositors' share, `amount - toCurator`.
    /// @custom:requirement R-SBY-4 R-FEE-2
    function splitCurator(uint256 amount, uint16 feeBps)
        internal
        pure
        returns (uint256 toCurator, uint256 toIdle)
    {
        if (feeBps > BPS_DENOMINATOR) revert InvalidBps(feeBps);
        toCurator = FixedPointMathLib.fullMulDiv(amount, feeBps, BPS_DENOMINATOR);
        // SAFETY: feeBps <= 10_000, so toCurator <= amount.
        unchecked {
            toIdle = amount - toCurator;
        }
    }
}
