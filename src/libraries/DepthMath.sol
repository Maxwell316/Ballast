// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title DepthMath
/// @notice Absorbable-collateral maths over a position's overlap with a price band (docs/MATH.md §3).
/// @dev "Absorbable collateral" is the amount of collateral that must be sold into the pool to move the price
/// across an interval. Every figure is net of swap fees and rounded **down** (conservative): it never overstates
/// depth (INV-9). Band edges follow `BandMath.bandEdges`: for collateral = currency0 the band is `[far, near]`
/// (ticks fall when collateral is sold in); for collateral = currency1 it is `[near, far]`.
library DepthMath {
    /// @notice A swap fee of 100% leaves no net amount, so no gross-up exists.
    error SwapFeeTooHigh(uint24 swapFee);

    uint256 private constant PIPS = 1_000_000;

    /// @notice Collateral absorbable by one position inside the anchor band (committed depth of a position).
    /// @dev Overlap of `[tickLower, tickUpper]` with the band, converted with `SqrtPriceMath.getAmount{0,1}Delta`
    /// (`roundUp = false`). Returns 0 for zero liquidity, an inverted band (its overlap is empty by construction:
    /// `hi < lo`), or an empty or zero-width overlap.
    /// @param collateralIs0 Whether the collateral is currency0.
    /// @param tickLower Position lower tick.
    /// @param tickUpper Position upper tick.
    /// @param liquidity Position liquidity.
    /// @param nearTick Band edge at the anchor.
    /// @param farTick Band edge in the liquidation direction.
    /// @return Collateral raw units, rounded down.
    /// @custom:requirement R-VIEW-1
    /// @custom:invariant INV-9
    function absorbable(
        bool collateralIs0,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        int24 nearTick,
        int24 farTick
    ) internal pure returns (uint256) {
        if (liquidity == 0) return 0;
        int24 lo;
        int24 hi;
        if (collateralIs0) {
            lo = tickLower > farTick ? tickLower : farTick;
            hi = tickUpper < nearTick ? tickUpper : nearTick;
        } else {
            lo = tickLower > nearTick ? tickLower : nearTick;
            hi = tickUpper < farTick ? tickUpper : farTick;
        }
        if (hi <= lo) return 0;
        uint160 sqrtLo = TickMath.getSqrtPriceAtTick(lo);
        uint160 sqrtHi = TickMath.getSqrtPriceAtTick(hi);
        return collateralIs0
            ? SqrtPriceMath.getAmount0Delta(sqrtLo, sqrtHi, liquidity, false)
            : SqrtPriceMath.getAmount1Delta(sqrtLo, sqrtHi, liquidity, false);
    }

    /// @notice Collateral absorbable by one position between the exact current price and `farTick`.
    /// @dev The near edge is the exact `sqrtSpotX96` (not a tick). Positions entirely behind the price (already
    /// converted) contribute 0; straddling positions contribute only the part between spot and the far edge.
    /// @param collateralIs0 Whether the collateral is currency0.
    /// @param tickLower Position lower tick.
    /// @param tickUpper Position upper tick.
    /// @param liquidity Position liquidity.
    /// @param sqrtSpotX96 Current sqrt price.
    /// @param farTick Far edge, `BandMath.bandEdges(spotTick, ...)`.
    /// @return Collateral raw units, rounded down.
    /// @custom:requirement R-VIEW-2
    /// @custom:invariant INV-9
    function liveAbsorbable(
        bool collateralIs0,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint160 sqrtSpotX96,
        int24 farTick
    ) internal pure returns (uint256) {
        if (liquidity == 0) return 0;
        uint160 sqrtLo;
        uint160 sqrtHi;
        if (collateralIs0) {
            // Price falls from spot to the far edge: interval [max(lower, far), min(spot, upper)].
            sqrtLo = TickMath.getSqrtPriceAtTick(tickLower > farTick ? tickLower : farTick);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
            sqrtHi = sqrtSpotX96 < sqrtUpper ? sqrtSpotX96 : sqrtUpper;
        } else {
            // Price rises from spot to the far edge: interval [max(spot, lower), min(upper, far)].
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
            sqrtLo = sqrtSpotX96 > sqrtLower ? sqrtSpotX96 : sqrtLower;
            sqrtHi = TickMath.getSqrtPriceAtTick(tickUpper < farTick ? tickUpper : farTick);
        }
        if (sqrtHi <= sqrtLo) return 0;
        return collateralIs0
            ? SqrtPriceMath.getAmount0Delta(sqrtLo, sqrtHi, liquidity, false)
            : SqrtPriceMath.getAmount1Delta(sqrtLo, sqrtHi, liquidity, false);
    }

    /// @notice The swap fee v4 applies to an input in the given direction (ADR-031).
    /// @dev Mirrors `Pool.swap`: `protocolFee == 0 ? lpFee : p + l - floor(p * l / 1e6)` with `p` the directional
    /// half of the packed protocol fee (low 12 bits for zeroForOne, high 12 bits for oneForZero; at most 1000 pips).
    /// The liquidation direction is zeroForOne iff the collateral is currency0.
    /// @param packedProtocolFee `slot0.protocolFee`.
    /// @param lpFee `slot0.lpFee` in pips.
    /// @param zeroForOne Direction of the swap.
    /// @return Effective swap fee in pips.
    /// @custom:requirement R-VIEW-2
    function effectiveSwapFee(uint24 packedProtocolFee, uint24 lpFee, bool zeroForOne)
        internal
        pure
        returns (uint24)
    {
        uint16 p = zeroForOne
            ? ProtocolFeeLibrary.getZeroForOneFee(packedProtocolFee)
            : ProtocolFeeLibrary.getOneForZeroFee(packedProtocolFee);
        return p == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(p, lpFee);
    }

    /// @notice Gross input needed to push `netAmount` of collateral through liquidity at `swapFee` pips.
    /// @dev `ceil(net * 1e6 / (1e6 - swapFee))`, rounded up: an upper bound on what a seller must pay. Optional
    /// helper; depth reported to consumers stays net of fees. Reverts `SwapFeeTooHigh` at or above 100%.
    /// @param netAmount Net (post-fee) amount.
    /// @param swapFee Effective swap fee in pips.
    /// @return Gross amount, rounded up.
    /// @custom:requirement R-VIEW-2
    function grossUp(uint256 netAmount, uint24 swapFee) internal pure returns (uint256) {
        if (swapFee >= PIPS) revert SwapFeeTooHigh(swapFee);
        return FixedPointMathLib.fullMulDivUp(netAmount, PIPS, PIPS - swapFee);
    }
}
