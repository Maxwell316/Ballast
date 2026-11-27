// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {BruteForce} from "../utils/BruteForce.sol";
import {ConfigFixture} from "../utils/ConfigFixture.sol";
import {Scenario, Scenarios} from "../utils/Scenario.sol";
import {DepthMath} from "../../src/libraries/DepthMath.sol";
import {Config, Position, Range} from "../../src/types/Types.sol";

/// @notice INV-9, differentially: for random vault layouts and random spot prices, the lens never reports more
/// collateral than a real swap through a plain v4 pool (same positions, no hook) absorbs between the same edges, and
/// never less than the same swap one tick short of the far edge, minus a stated rounding allowance. The expected
/// values come from the PoolManager's swap maths and its fee accounting (`test/utils/BruteForce.sol`) and from the
/// committed tick table for the band edges (`test/data/band_ticks_ref.json`, 80-digit reference), not from
/// `DepthMath`, `BandMath`, the lens or the vaults.
///
/// Coverage per run: both collateral orderings, decimals 18/6, 6/18 and 18/18, swap fee 0 and non-zero, a non-zero
/// protocol fee on both the Ballast pool and the plain pool, the lens built before or after the pool is initialised,
/// pool-wide and per-vault depth, committed and live, and exit netting through the horizon.
/// @dev Tolerance. Upper side: `lens <= wide` is exact (no allowance), where `wide` is the measured net input to the
/// exact floor of the reference tick table; BandMath may be one tick narrower (docs/MATH.md §2). Lower side:
/// `lens >= narrow - tolerance(positions)`, where `narrow` is the measured net input to one tick short of the table
/// value and `tolerance = 3 * positions + 6` wei: at most 1 wei per swap-step round-up, per reported-amount round-down
/// and per fee round-down (`BruteForce`). The lens and the plain pool see the same positions; any larger gap is a bug.
/// @custom:invariant INV-9
/// @custom:requirement R-VIEW-1 R-VIEW-2
contract LensDifferentialTest is BruteForce {
    using StateLibrary for IPoolManager;

    uint16 internal constant BAND_BPS = 750; // ConfigFixture.compressed().bandBps

    struct Run {
        bool c0;
        uint8 cd;
        uint8 qd;
        uint24 fee;
        uint24 protocolFee;
        int24 center;
        uint16 impactBps;
        uint256 nVaults;
    }

    function _h(uint256 seed, string memory tag, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, tag, i)));
    }

    function _vaultPositions(uint256 seed, uint256 v, int24 center)
        internal
        pure
        returns (Position[] memory ps)
    {
        uint256 n = 1 + _h(seed, "n", v) % 3;
        ps = new Position[](n);
        for (uint256 i; i < n; ++i) {
            int256 k = int256(_h(seed, "k", v * 8 + i) % 501) - 250;
            // Widths are 3a + i ticks-of-spacing: distinct residues mod 3 make the ranges of one vault unique.
            uint256 w = 3 * (1 + _h(seed, "w", v * 8 + i) % 100) + i;
            // SAFETY: |k| <= 250, w <= 303, spacing 60, center <= 276,324 + margin: far inside int24.
            // forge-lint: disable-start(unsafe-typecast)
            int24 lo = center + int24(k * 60);
            ps[i] = Position(
                lo,
                lo + int24(uint24(w) * 60),
                uint128(1e14 + _h(seed, "l", v * 8 + i) % (1e20 - 1e14))
            );
            // forge-lint: disable-end(unsafe-typecast)
        }
    }

    function _setUpRun(uint256 seed, bool lensAfter) internal returns (Run memory r) {
        uint8[3] memory cds = [18, 6, 18];
        uint8[3] memory qds = [6, 18, 18];
        uint256 d = seed % 3;
        r.c0 = (seed >> 8) % 2 == 0;
        r.cd = cds[d];
        r.qd = qds[d];
        uint24[4] memory fees = [uint24(0), 500, 3000, 10_000];
        r.fee = fees[(seed >> 16) % 4];
        if ((seed >> 24) % 2 == 1) {
            uint24 p0 = uint24(1 + _h(seed, "p0", 0) % 1000);
            uint24 p1 = uint24(1 + _h(seed, "p1", 0) % 1000);
            r.protocolFee = p0 | (p1 << 12);
        }
        r.impactBps = uint16(100 + _h(seed, "imp", 0) % 2401);
        r.nVaults = 1 + _h(seed, "nv", 0) % 3;
        r.center = Scenarios.make(r.c0, r.cd, r.qd).startTick;

        Config memory c = ConfigFixture.compressed();
        c.fee = r.fee;
        mintAmount = 1e36;
        lensAfterInit = lensAfter;
        _setUpWith(r.c0, r.cd, r.qd, c, r.center);
        pm.setProtocolFeeController(address(this));
        if (r.protocolFee != 0) pm.setProtocolFee(key, r.protocolFee);
    }

    /// @dev Moves the Ballast pool's spot to `target` with a real swap (either direction, price-limited).
    function _moveSpotTo(int24 target) internal {
        int24 now_ = _tick();
        if (target == now_) return;
        bool zeroForOne = target < now_;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1e29),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Pool-wide and per-vault committed and live depth against brute force, with and without exit netting.
    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: ci.fuzz.runs = 5000
    function testFuzz_Inv9_LensNeverOverstates_AndIsTight(uint256 seed, bool lensAfter) public {
        Run memory r = _setUpRun(seed, lensAfter);

        // Layout: 1..3 vaults of 1..3 positions, commitments cycling through {1, 1e15, 1e30} (never in breach: no
        // time passes), and an exit ticket on every other vault for a random share fraction.
        Position[][] memory layout = new Position[][](r.nVaults);
        uint128[3] memory commitments = [uint128(1), 1e15, 1e30];
        uint256[] memory exiting = new uint256[](r.nVaults);
        for (uint256 v = 1; v <= r.nVaults; ++v) {
            Position[] memory ps = _vaultPositions(seed, v, r.center);
            layout[v - 1] = ps;
            Range[] memory rg = new Range[](ps.length);
            uint128[] memory ls = new uint128[](ps.length);
            for (uint256 i; i < ps.length; ++i) {
                rg[i] = Range(ps[i].tickLower, ps[i].tickUpper);
                ls[i] = ps[i].liquidity;
            }
            vaults.createVault(rg, commitments[v % 3], 0);
            vaults.seed(v, ls, type(uint128).max, type(uint128).max, address(this));
            if (v % 2 == 0) {
                exiting[v - 1] = (1e18 * (1 + _h(seed, "ex", v) % 99)) / 100; // 1%..99% of INITIAL_SHARES
                vaults.requestRedeem(v, uint128(exiting[v - 1]));
            }
        }
        // The anchor is a TWAP, so it is only defined once time has passed. Let 300 s elapse at the initial tick, then
        // move the spot in one swap: the swap accumulates the pre-swap tick over those 300 s, so the anchor is the
        // initial tick exactly, whatever the spot becomes. (With zero elapsed time the hook reports the spot tick.)
        vm.warp(vm.getBlockTimestamp() + 300);
        // Random spot: a real swap moves the Ballast pool up to about +-9,000 ticks from the anchor.
        // SAFETY: |k| <= 150, spacing 60.
        // forge-lint: disable-next-line(unsafe-typecast)
        _moveSpotTo(r.center + int24(int256(_h(seed, "spot", 0) % 301) - 150) * 60);

        assertEq(
            hook.stressInfo().anchorTick, r.center, "precondition: the anchor is the initial tick"
        );
        (uint160 sqrtP, int24 spot,,) = IPoolManager(address(pm)).getSlot0(pid);
        int24 liveFar = _farEdge(spot, r.impactBps);
        int24 bandFar = _farEdge(r.center, BAND_BPS);
        uint160 sqrtAnchor = TickMath.getSqrtPriceAtTick(r.center);

        // ── pool-wide live depth: every position in one plain pool, one swap ──
        Position[] memory all = _flatten(layout);
        {
            Plain memory p = _plainPool(all, sqrtP, r.fee, r.protocolFee);
            (uint256 narrow, uint256 wide, uint256 gross) = _absorbTwoStage(p, liveFar);
            uint256 got = lens.poolAbsorbable(r.impactBps);
            assertLe(
                got, wide, "pool-wide live depth overstates the measured absorbable collateral"
            );
            assertGe(
                got + tolerance(all.length),
                narrow,
                "pool-wide live depth is looser than the allowance"
            );
            _checkGrossUp(p, wide, gross, all.length);
        }

        // ── per vault: live and committed, then the totals ──
        uint256 sumLive0Hi;
        uint256 sumLive0Lo;
        uint256 sumLiveHHi;
        uint256 sumLiveHLo;
        uint256 sumCommHi;
        uint256 sumCommLo;
        for (uint256 v = 1; v <= r.nVaults; ++v) {
            Position[] memory ps = layout[v - 1];
            uint256 s = vaults.shareToken().totalSupply(v);
            uint256 e = exiting[v - 1];
            uint256 tol = tolerance(ps.length);

            Plain memory live = _plainPool(ps, sqrtP, r.fee, r.protocolFee);
            (uint256 lNarrow, uint256 lWide,) = _absorbTwoStage(live, liveFar);
            Plain memory comm = _plainPool(ps, sqrtAnchor, r.fee, r.protocolFee);
            (uint256 cNarrow, uint256 cWide,) = _absorbTwoStage(comm, bandFar);

            uint256 depth = lens.vaultDepth(v);
            assertLe(depth, cWide, "committed depth overstates");
            assertGe(depth + tol, cNarrow, "committed depth is looser than the allowance");

            // The stateless calculator the vaults use for coverage and standby sampling (`vaults.depthCalc`) is held to
            // the same measurements: committed over the 750 bps band at the anchor, live over the random impact.
            (uint256 vc,) = vaults.depthCalc()
                .measure(collateralIs0, r.center, spot, sqrtP, uint24(_tableTicks(BAND_BPS)), ps);
            (, uint256 vl) = vaults.depthCalc()
                .measure(collateralIs0, r.center, spot, sqrtP, uint24(_tableTicks(r.impactBps)), ps);
            assertLe(vc, cWide, "vaults' committed depth overstates");
            assertGe(vc + tol, cNarrow, "vaults' committed depth is looser than the allowance");
            assertLe(vl, lWide, "vaults' live depth overstates");
            assertGe(vl + tol, lNarrow, "vaults' live depth is looser than the allowance");

            uint256 k = commitments[v % 3];
            sumCommHi += cWide < k ? cWide : k;
            sumCommLo += (cNarrow > tol ? cNarrow - tol : 0) < k
                ? (cNarrow > tol ? cNarrow - tol : 0)
                : k;

            // Maximum netting (the horizon covers the ticket) uses (s - e)/s; no netting uses 1.
            sumLive0Hi += lWide;
            sumLive0Lo += FullMath.mulDiv(lNarrow > tol ? lNarrow - tol : 0, s - e, s);
            sumLiveHHi += FullMath.mulDiv(lWide, s - e, s);
            sumLiveHLo += FullMath.mulDiv(lNarrow > tol ? lNarrow - tol : 0, s - e, s);
        }
        // committedDepth sums min(D_v, commitment_v) over vaults not in breach.
        uint256 committed = lens.committedDepth();
        assertLe(committed, sumCommHi, "committedDepth overstates");
        assertGe(committed + r.nVaults, sumCommLo, "committedDepth is looser than the allowance");

        // liveDepth with a horizon that covers every ticket (maturity = now + exitNotice = 600 s): exact netting.
        uint256 liveH = lens.liveDepth(r.impactBps, 600);
        assertLe(liveH, sumLiveHHi, "liveDepth(horizon) overstates");
        assertGe(liveH + r.nVaults, sumLiveHLo, "liveDepth(horizon) is looser than the allowance");
        // Horizon 0: netting may count the ticket (buckets round maturities down, so never less than exact) or not;
        // the figure lies between the fully netted lower bound and the un-netted upper bound.
        uint256 live0 = lens.liveDepth(r.impactBps, 0);
        assertLe(live0, sumLive0Hi, "liveDepth(0) overstates");
        assertGe(
            live0 + r.nVaults, sumLive0Lo, "liveDepth(0) is below even the fully netted figure"
        );
    }

    /// @dev The gross input of the swap equals `DepthMath.grossUp(net, effectiveSwapFee)` up to the step round-ups:
    /// the one place the library's fee helpers (protocol fee combination included) are checked against v4 itself.
    function _checkGrossUp(Plain memory p, uint256 wide, uint256 gross, uint256 n) internal view {
        (,, uint24 packed, uint24 lpFee) =
            IPoolManager(address(pm)).getSlot0(PoolIdLibrary.toId(p.key));
        uint24 eff = DepthMath.effectiveSwapFee(packed, lpFee, collateralIs0);
        uint256 up = DepthMath.grossUp(wide, eff);
        assertLe(up, gross + tolerance(n), "gross-up is above what the swap paid");
        assertLe(gross, up + tolerance(n), "gross-up is below what the swap paid");
    }

    function _flatten(Position[][] memory layout) internal pure returns (Position[] memory out) {
        uint256 n;
        for (uint256 v; v < layout.length; ++v) {
            n += layout[v].length;
        }
        out = new Position[](n);
        uint256 j;
        for (uint256 v; v < layout.length; ++v) {
            for (uint256 i; i < layout[v].length; ++i) {
                out[j++] = layout[v][i];
            }
        }
    }
}
