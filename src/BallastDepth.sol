// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BandMath} from "./libraries/BandMath.sol";
import {DepthMath} from "./libraries/DepthMath.sol";
import {Position} from "./types/Types.sol";

/// @title BallastDepth
/// @notice Stateless depth calculator used by `BallastVaults` for coverage and standby sampling (ADR-050). It is a
/// thin external wrapper over `DepthMath` and `BandMath`, the same library code the lens runs, so there is a single
/// source of truth for depth (differential test: `test/fuzz/BallastDepthDifferential.t.sol`).
/// @dev Holds no state and no funds and calls nothing. The vaults trust it only as part of the same immutable
/// deployment: they create it in their constructor.
contract BallastDepth {
    /// @notice Committed (anchor band) and live (spot band) absorbable collateral of `positions`.
    /// @param collateralIs0 Whether the collateral is currency0.
    /// @param anchorTick Anchor tick; the band runs from it in the liquidation direction.
    /// @param spotTick Current pool tick.
    /// @param sqrtSpotX96 Current sqrt price.
    /// @param bandTicks Band length in ticks.
    /// @param positions The vault's positions.
    /// @return committed Sum over positions of `DepthMath.absorbable` in the anchor band (rounded down).
    /// @return live Sum over positions of `DepthMath.liveAbsorbable` from spot (rounded down).
    function measure(
        bool collateralIs0,
        int24 anchorTick,
        int24 spotTick,
        uint160 sqrtSpotX96,
        uint24 bandTicks,
        Position[] calldata positions
    ) external pure returns (uint256 committed, uint256 live) {
        (int24 near, int24 far) = BandMath.bandEdges(anchorTick, collateralIs0, bandTicks);
        // slither-disable-next-line unused-return
        (, int24 farSpot) = BandMath.bandEdges(spotTick, collateralIs0, bandTicks);
        for (uint256 i; i < positions.length; ++i) {
            Position calldata p = positions[i];
            committed += DepthMath.absorbable(
                collateralIs0, p.tickLower, p.tickUpper, p.liquidity, near, far
            );
            live += DepthMath.liveAbsorbable(
                collateralIs0, p.tickLower, p.tickUpper, p.liquidity, sqrtSpotX96, farSpot
            );
        }
    }

    /// @notice Minimal liquidity to remove from a position so the removal returns at least `shortfall` of one
    /// currency at the current price (the re-range dust rule, ADR-049).
    /// @dev `unit` is the amount of the chosen currency that 1e18 liquidity represents at spot, rounded down; the
    /// result is `ceil(shortfall * 1e18 / unit) + 1`. Returns 0 if the position holds none of that currency
    /// (nothing to shrink) or if the result would remove the whole position, so the caller reverts.
    /// @param tickLower Position lower tick.
    /// @param tickUpper Position upper tick.
    /// @param liquidity Position liquidity.
    /// @param sqrtSpotX96 Current sqrt price.
    /// @param shortfall Amount of the currency still missing.
    /// @param token0 Whether the missing currency is currency0.
    function shrinkLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint160 sqrtSpotX96,
        uint256 shortfall,
        bool token0
    ) external pure returns (uint256 dl) {
        uint160 lo = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 unit;
        if (token0) {
            if (sqrtSpotX96 < hi) {
                unit = SqrtPriceMath.getAmount0Delta(
                    sqrtSpotX96 > lo ? sqrtSpotX96 : lo, hi, 1e18, false
                );
            }
        } else if (sqrtSpotX96 > lo) {
            unit =
                SqrtPriceMath.getAmount1Delta(lo, sqrtSpotX96 < hi ? sqrtSpotX96 : hi, 1e18, false);
        }
        if (unit == 0) return 0;
        dl = FixedPointMathLib.fullMulDivUp(shortfall, 1e18, unit) + 1;
        if (dl >= liquidity) return 0;
    }
}
