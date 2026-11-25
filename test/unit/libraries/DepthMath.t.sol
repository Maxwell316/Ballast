// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {DepthMath} from "../../../src/libraries/DepthMath.sol";
import {BandMath} from "../../../src/libraries/BandMath.sol";
import {Scenario, Scenarios} from "../../utils/Scenario.sol";

contract DepthMathHarness {
    function grossUp(uint256 n, uint24 f) external pure returns (uint256) {
        return DepthMath.grossUp(n, f);
    }
}

/// @notice Unit and property tests for DepthMath. Every band and depth test covers both collateral directions and
/// every decimals/ordering scenario through `Scenarios.all()` (the anchor is the scenario's start tick). The
/// differential test against a real PoolManager is in `test/fuzz/DifferentialDepthMath.t.sol`.
contract DepthMathTest is Test {
    DepthMathHarness internal h = new DepthMathHarness();
    uint128 internal constant L = 1e18;
    int24 internal constant SP = 60;

    function _scaled(int24 anchor, int24 delta) internal pure returns (int24) {
        return anchor + delta;
    }

    /// @notice Independent anchor: `L * (1.0001^389.5 - 1)` computed off-chain with 60-digit decimals
    /// (39716471710846406.81...). Both directions give the same number for the mirrored position.
    /// @custom:requirement R-VIEW-1
    function test_WorkedExample_MatchesOffChainReference_BothDirections() public pure {
        uint256 ref = 39_716_471_710_846_406; // floor of the 60-digit value
        // Collateral token0, anchor 0, position [-1200, 0], band 779 ticks: overlap [-779, 0].
        (int24 near0, int24 far0) = BandMath.bandEdges(0, true, 779);
        uint256 a0 = DepthMath.absorbable(true, -1200, 0, L, near0, far0);
        // Collateral token1, anchor 0, position [0, 1200]: overlap [0, 779].
        (int24 near1, int24 far1) = BandMath.bandEdges(0, false, 779);
        uint256 a1 = DepthMath.absorbable(false, 0, 1200, L, near1, far1);
        // TickMath's sqrt prices are rounded; allow 1e-12 relative error and require "never overstates by more".
        assertApproxEqRel(a0, ref, 1e6, "token0 example");
        assertApproxEqRel(a1, ref, 1e6, "token1 example");
    }

    /// @custom:requirement R-VIEW-1
    function test_PartialOverlap_MatchesOffChainReference() public pure {
        // Position [-300, 100], anchor 0, collateral token0, band 779: overlap [-300, 0] = L*(1.0001^150 - 1).
        (int24 near, int24 far) = BandMath.bandEdges(0, true, 779);
        uint256 got = DepthMath.absorbable(true, -300, 100, L, near, far);
        assertApproxEqRel(got, 15_112_303_331_957_826, 1e6);
    }

    /// @custom:requirement R-VIEW-1
    function test_EmptyAndDegenerateInputs_AreZero_AllScenarios() public pure {
        Scenario[] memory all = Scenarios.all();
        for (uint256 i; i < all.length; ++i) {
            bool c0 = all[i].collateralIs0;
            int24 a = all[i].startTick;
            (int24 near, int24 far) = BandMath.bandEdges(a, c0, 779);
            // Zero liquidity.
            assertEq(DepthMath.absorbable(c0, a - 600, a + 600, 0, near, far), 0);
            // Position entirely outside the band on the far side and on the near side.
            if (c0) {
                assertEq(
                    DepthMath.absorbable(true, far - 1200, far, L, near, far), 0, "below far edge"
                );
                assertEq(
                    DepthMath.absorbable(true, near, near + 1200, L, near, far),
                    0,
                    "above near edge"
                );
            } else {
                assertEq(
                    DepthMath.absorbable(false, far, far + 1200, L, near, far), 0, "above far edge"
                );
                assertEq(
                    DepthMath.absorbable(false, near - 1200, near, L, near, far),
                    0,
                    "below near edge"
                );
            }
            // Zero-width band and inverted band.
            assertEq(DepthMath.absorbable(c0, a - 600, a + 600, L, near, near), 0, "zero width");
            assertEq(DepthMath.absorbable(c0, a - 600, a + 600, L, far, near), 0, "inverted band");
        }
    }

    /// @notice Both directions, all scenarios: a position covering the whole band absorbs more than any sub-range,
    /// is monotonic in liquidity and in band width, and splits additively up to rounding.
    /// @custom:requirement R-VIEW-1
    function test_Properties_AllScenarios_BothDirections() public pure {
        Scenario[] memory all = Scenarios.all();
        for (uint256 i; i < all.length; ++i) {
            bool c0 = all[i].collateralIs0;
            int24 a = all[i].startTick;
            uint24 band = BandMath.bpsToTicksDown(750);
            (int24 near, int24 far) = BandMath.bandEdges(a, c0, band);
            int24 lo = a - 1200;
            int24 hi = a + 1200;

            uint256 whole = DepthMath.absorbable(c0, lo, hi, L, near, far);
            assertGt(whole, 0, "covering position absorbs depth");

            // Monotonic in liquidity.
            assertLe(DepthMath.absorbable(c0, lo, hi, L / 2, near, far), whole);
            assertGe(DepthMath.absorbable(c0, lo, hi, L * 2, near, far), whole);

            // Monotonic in band width.
            (, int24 farWide) = BandMath.bandEdges(a, c0, band * 2);
            assertGe(DepthMath.absorbable(c0, lo, hi, L, near, farWide), whole);
            (, int24 farNarrow) = BandMath.bandEdges(a, c0, band / 2);
            assertLe(DepthMath.absorbable(c0, lo, hi, L, near, farNarrow), whole);

            // Additive over a split of the band (sum of parts never exceeds the whole, within 2 wei of it).
            int24 mid = c0 ? near - int24(band / 2) : near + int24(band / 2);
            uint256 p1 = DepthMath.absorbable(c0, lo, hi, L, near, mid);
            uint256 p2 = DepthMath.absorbable(c0, lo, hi, L, mid, far);
            assertLe(p1 + p2, whole);
            assertLe(whole - (p1 + p2), 4);
        }
    }

    /// @custom:requirement R-VIEW-2
    function test_LiveAbsorbable_EqualsAbsorbable_WhenSpotIsExactlyAtNearTick_AllScenarios()
        public
        pure
    {
        Scenario[] memory all = Scenarios.all();
        for (uint256 i; i < all.length; ++i) {
            bool c0 = all[i].collateralIs0;
            int24 a = all[i].startTick;
            (int24 near, int24 far) = BandMath.bandEdges(a, c0, BandMath.bpsToTicksDown(750));
            uint160 spot = TickMath.getSqrtPriceAtTick(a);
            assertEq(
                DepthMath.liveAbsorbable(c0, a - 1200, a + 1200, L, spot, far),
                DepthMath.absorbable(c0, a - 1200, a + 1200, L, near, far)
            );
            // A position entirely behind the price (already converted) contributes nothing.
            if (c0) {
                assertEq(
                    DepthMath.liveAbsorbable(true, a + 60, a + 1200, L, spot, far),
                    0,
                    "above spot, token0 side"
                );
            } else {
                assertEq(
                    DepthMath.liveAbsorbable(false, a - 1200, a - 60, L, spot, far),
                    0,
                    "below spot, token1 side"
                );
            }
        }
    }

    /// @notice Live depth shrinks as the spot moves in the liquidation direction (the market consumes it).
    /// @custom:requirement R-VIEW-2
    function testFuzz_LiveAbsorbable_ShrinksAsSpotMovesTowardFarEdge(uint8 scen, uint16 move)
        public
        pure
    {
        Scenario[] memory all = Scenarios.all();
        Scenario memory s = all[scen % all.length];
        int24 a = s.startTick;
        uint24 band = BandMath.bpsToTicksDown(750);
        (, int24 far) = BandMath.bandEdges(a, s.collateralIs0, band);
        int24 m = int24(uint24(move % (band - 1)));
        int24 movedTick = s.collateralIs0 ? a - m : a + m;
        uint160 spot0 = TickMath.getSqrtPriceAtTick(a);
        uint160 spot1 = TickMath.getSqrtPriceAtTick(movedTick);
        uint256 d0 = DepthMath.liveAbsorbable(s.collateralIs0, a - 1200, a + 1200, L, spot0, far);
        uint256 d1 = DepthMath.liveAbsorbable(s.collateralIs0, a - 1200, a + 1200, L, spot1, far);
        assertLe(d1, d0);
    }

    /// @custom:requirement R-VIEW-2
    function test_EffectiveSwapFee_MatchesV4Formula() public pure {
        uint24 packed = (uint24(700) << 12) | uint24(400); // oneForZero 700, zeroForOne 400
        // zeroForOne uses the low half.
        assertEq(
            DepthMath.effectiveSwapFee(packed, 3000, true),
            ProtocolFeeLibrary.calculateSwapFee(400, 3000)
        );
        assertEq(
            DepthMath.effectiveSwapFee(packed, 3000, false),
            ProtocolFeeLibrary.calculateSwapFee(700, 3000)
        );
        // No protocol fee: just the LP fee.
        assertEq(DepthMath.effectiveSwapFee(0, 3000, true), 3000);
        // 400 + 3000 - floor(400*3000/1e6) = 3400 - 1 = 3399
        assertEq(DepthMath.effectiveSwapFee(packed, 3000, true), 3399);
        // Direction with a zero half falls back to the LP fee.
        assertEq(DepthMath.effectiveSwapFee(uint24(400), 3000, false), 3000);
    }

    /// @custom:requirement R-VIEW-2
    function testFuzz_GrossUp_IsUpperBoundOfInverse(uint128 net, uint24 feeRaw) public pure {
        uint24 fee = uint24(bound(uint256(feeRaw), 0, 999_999));
        uint256 keep = 1_000_000 - uint256(fee);
        uint256 gross = DepthMath.grossUp(net, fee);
        assertGe(gross, net);
        // Applying the fee to the gross amount (floor) returns at least `net`.
        assertGe(gross * keep / 1_000_000, net);
        // And it is the smallest such gross amount: one less would fall short of `net` before rounding.
        if (gross > 0) assertLt((gross - 1) * keep, uint256(net) * 1_000_000);
    }

    /// @custom:requirement R-VIEW-2
    function test_RevertWhen_SwapFeeIs100Percent() public {
        vm.expectRevert(
            abi.encodeWithSelector(DepthMath.SwapFeeTooHigh.selector, uint24(1_000_000))
        );
        h.grossUp(1, 1_000_000);
        assertEq(DepthMath.grossUp(1000, 0), 1000);
        assertEq(DepthMath.grossUp(997, 3000), 1000); // 997 * 1e6 / 997000 = 1000 exactly
    }
}
