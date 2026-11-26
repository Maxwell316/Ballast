// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BallastDepth} from "../../src/BallastDepth.sol";
import {BandMath} from "../../src/libraries/BandMath.sol";
import {DepthMath} from "../../src/libraries/DepthMath.sol";
import {Position} from "../../src/types/Types.sol";

/// @notice The stateless depth contract the vaults trust returns exactly what the library code (also run by the lens)
/// returns, over fuzzed positions, anchors, spots and bands (single source of truth, ADR-050).
/// @custom:invariant INV-9
contract BallastDepthDifferentialTest is Test {
    BallastDepth internal depth = new BallastDepth();

    function _pos(uint256 seed, uint256 i) internal pure returns (Position memory p) {
        int256 a = int256(bound(uint256(keccak256(abi.encode(seed, i, "a"))), 0, 2000)) - 1000;
        int256 b = int256(bound(uint256(keccak256(abi.encode(seed, i, "b"))), 1, 1000));
        // SAFETY: |a * 60| <= 60,000 and b * 60 <= 60,000, within int24.
        // forge-lint: disable-start(unsafe-typecast)
        p.tickLower = int24(a * 60);
        p.tickUpper = int24((a + b) * 60);
        // forge-lint: enable-start(unsafe-typecast)
        p.liquidity = uint128(bound(uint256(keccak256(abi.encode(seed, i, "l"))), 0, 1e24));
    }

    function testFuzz_Measure_EqualsLibrary(
        uint256 seed,
        bool c0,
        int24 anchor,
        int24 spot,
        uint16 bandBps,
        uint8 n
    ) public view {
        anchor = int24(bound(anchor, -50_000, 50_000));
        spot = int24(bound(spot, -50_000, 50_000));
        uint24 bandTicks = BandMath.bpsToTicksDown(uint16(bound(bandBps, 100, 2500)));
        uint256 count = bound(n, 0, 8);
        Position[] memory ps = new Position[](count);
        for (uint256 i; i < count; ++i) {
            ps[i] = _pos(seed, i);
        }
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(spot);

        (uint256 committed, uint256 live) = depth.measure(c0, anchor, spot, sqrtP, bandTicks, ps);

        (int24 near, int24 far) = BandMath.bandEdges(anchor, c0, bandTicks);
        (, int24 farSpot) = BandMath.bandEdges(spot, c0, bandTicks);
        uint256 expC;
        uint256 expL;
        for (uint256 i; i < count; ++i) {
            expC += DepthMath.absorbable(
                c0, ps[i].tickLower, ps[i].tickUpper, ps[i].liquidity, near, far
            );
            expL += DepthMath.liveAbsorbable(
                c0, ps[i].tickLower, ps[i].tickUpper, ps[i].liquidity, sqrtP, farSpot
            );
        }
        assertEq(committed, expC, "committed");
        assertEq(live, expL, "live");
    }

    /// @notice The shrink formula removes at least the shortfall: the returned liquidity, valued at spot, covers it.
    function testFuzz_ShrinkLiquidity_CoversShortfallOrReturnsZero(
        int24 spot,
        uint128 liquidity,
        uint64 shortfall,
        bool token0
    ) public view {
        spot = int24(bound(spot, -3000, 3000));
        liquidity = uint128(bound(liquidity, 1e6, 1e24));
        uint256 sf = bound(shortfall, 1, 1e12);
        int24 lo = -6000;
        int24 hi = 6000;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(spot);
        uint256 dl = depth.shrinkLiquidity(lo, hi, liquidity, sqrtP, sf, token0);
        if (dl == 0) return;
        assertLt(dl, liquidity, "never removes the whole position");
        // Value of dl liquidity of the chosen currency at spot, rounded down, must be at least the shortfall.
        uint160 sLo = TickMath.getSqrtPriceAtTick(lo);
        uint160 sHi = TickMath.getSqrtPriceAtTick(hi);
        uint256 got = token0
            ? (uint256(dl) * uint256(sHi - sqrtP) * (1 << 96)) / (uint256(sHi) * uint256(sqrtP))
            : (uint256(dl) * uint256(sqrtP - sLo)) >> 96;
        assertGe(got + 2, sf, "removal covers the shortfall (within rounding of the check itself)");
    }

    /// @notice Edge cases of the dust-shrink formula: a position that holds none of the missing currency, spot outside
    /// the range on either side, and a shortfall so large the whole position would go.
    function test_ShrinkLiquidity_EdgeCases() public view {
        int24 lo = -600;
        int24 hi = 600;
        uint160 inside = TickMath.getSqrtPriceAtTick(0);
        uint160 below = TickMath.getSqrtPriceAtTick(-1200);
        uint160 above = TickMath.getSqrtPriceAtTick(1200);
        // Missing token0 but spot is at or above the range: the position holds only token1.
        assertEq(depth.shrinkLiquidity(lo, hi, 1e18, above, 100, true), 0);
        // Missing token1 but spot is at or below the range: the position holds only token0.
        assertEq(depth.shrinkLiquidity(lo, hi, 1e18, below, 100, false), 0);
        // Spot below the range: token0 is priced over the whole range (lower bound is the range's own).
        assertGt(depth.shrinkLiquidity(lo, hi, 1e18, below, 100, true), 0);
        // Spot above the range: token1 is priced over the whole range.
        assertGt(depth.shrinkLiquidity(lo, hi, 1e18, above, 100, false), 0);
        // Inside the range both currencies work.
        assertGt(depth.shrinkLiquidity(lo, hi, 1e18, inside, 100, true), 0);
        assertGt(depth.shrinkLiquidity(lo, hi, 1e18, inside, 100, false), 0);
        // A shortfall that would remove the whole position returns zero (the caller reverts).
        assertEq(depth.shrinkLiquidity(lo, hi, 10, inside, 1e18, true), 0);
    }
}
