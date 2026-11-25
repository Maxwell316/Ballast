// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {DepthMath} from "../../src/libraries/DepthMath.sol";
import {BandMath} from "../../src/libraries/BandMath.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {Scenario, Scenarios} from "../utils/Scenario.sol";

/// @notice Differential test (INV-9): `DepthMath` against a real, hookless PoolManager. The liquidation sell is
/// executed with a `sqrtPriceLimit` at the far edge tick, so the swap stops exactly there. Measured input, net of
/// the LP fee (collected by poking every position) and of the protocol fee (`protocolFeesAccrued`), must be at least
/// `DepthMath`'s figure (never overstated) and within a small rounding bound of it. Runs every decimals/ordering
/// scenario in both collateral directions, with LP fee > 0 and a nonzero protocol fee in the liquidation direction.
contract DifferentialDepthMathTest is Test {
    using StateLibrary for PoolManager;
    using PoolIdLibrary for PoolKey;

    struct Pos {
        int24 lo;
        int24 hi;
        uint128 liq;
        bytes32 salt;
    }

    PoolManager internal pm;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liqRouter;

    uint24[3] internal lpFees = [uint24(0), 3000, 10_000];
    uint16[3] internal protocolFees = [uint16(0), 400, 1000]; // pips, MAX_PROTOCOL_FEE = 1000

    function setUp() public {
        pm = new PoolManager(address(this));
        pm.setProtocolFeeController(address(this));
        swapRouter = new PoolSwapTest(pm);
        liqRouter = new PoolModifyLiquidityTest(pm);
    }

    struct Result {
        uint256 expected; // DepthMath
        uint256 netMeasured; // swap input net of LP and protocol fee
        uint256 grossMeasured;
        uint256 grossUpOfExpected;
        uint24 swapFee;
        bool reachedLimit;
        uint256 positions;
    }

    function _positions(uint256 seed, int24 anchor, uint256 n)
        internal
        pure
        returns (Pos[] memory ps)
    {
        ps = new Pos[](n);
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            int24 lo = anchor + int24(int256(r % 121) - 60) * Scenarios.SPACING;
            int24 hi = lo + int24(int256((r >> 16) % 60 + 1)) * Scenarios.SPACING;
            if (i == 0) {
                // The first position always covers the widest band (2500 bps is about 2_900 ticks) so every case has depth.
                lo = anchor - 60 * Scenarios.SPACING;
                hi = anchor + 60 * Scenarios.SPACING;
            }
            ps[i] = Pos(lo, hi, uint128(1e12 + (r >> 32) % 1e24), bytes32(i + 1));
        }
    }

    function _deployTokens(Scenario memory s)
        internal
        returns (MockERC20 coll, MockERC20 quote, PoolKey memory k)
    {
        address low = address(0x1000);
        address high = address(0x2000);
        address collAddr = s.collateralIs0 ? low : high;
        address quoteAddr = s.collateralIs0 ? high : low;
        deployCodeTo(
            "MockERC20.sol:MockERC20", abi.encode("C", "C", s.collateralDecimals), collAddr
        );
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Q", "Q", s.quoteDecimals), quoteAddr);
        coll = MockERC20(collAddr);
        quote = MockERC20(quoteAddr);
        coll.mint(address(this), 1 << 127);
        quote.mint(address(this), 1 << 127);
        coll.approve(address(swapRouter), type(uint256).max);
        coll.approve(address(liqRouter), type(uint256).max);
        quote.approve(address(swapRouter), type(uint256).max);
        quote.approve(address(liqRouter), type(uint256).max);
        k = PoolKey(
            Currency.wrap(low), Currency.wrap(high), 0, Scenarios.SPACING, IHooks(address(0))
        );
    }

    struct Params {
        Scenario s;
        uint16 bps;
        uint24 lpFee;
        uint16 protocolFee;
        uint256 seed;
        uint256 n;
        bool live;
    }

    function _initPool(Params memory p) internal returns (PoolKey memory key, uint160 spot) {
        (,, key) = _deployTokens(p.s);
        key.fee = p.lpFee;
        spot = TickMath.getSqrtPriceAtTick(p.s.startTick);
        if (p.live) {
            // Spot strictly inside the tick above the start tick.
            uint160 next = TickMath.getSqrtPriceAtTick(p.s.startTick + 1);
            spot += uint160(uint256(keccak256(abi.encode(p.seed, "frac"))) % (next - spot - 1)) + 1;
        }
        pm.initialize(key, spot);
        if (p.protocolFee > 0) {
            // Liquidation-direction half = protocolFee; the other half differs, proving the direction is selected
            // correctly (zeroForOne = low 12 bits).
            uint24 other = p.protocolFee == 1000 ? 300 : 900;
            uint24 packed = p.s.collateralIs0
                ? (other << 12) | p.protocolFee
                : (uint24(p.protocolFee) << 12) | other;
            pm.setProtocolFee(key, packed);
        }
    }

    function _expectedDepth(Params memory p, Pos[] memory ps, uint160 spot)
        internal
        pure
        returns (uint256 total, int24 far)
    {
        uint24 band = BandMath.bpsToTicksDown(p.bps);
        int24 near;
        (near, far) = BandMath.bandEdges(
            p.live ? TickMath.getTickAtSqrtPrice(spot) : p.s.startTick, p.s.collateralIs0, band
        );
        for (uint256 i; i < ps.length; ++i) {
            total += p.live
                ? DepthMath.liveAbsorbable(
                    p.s.collateralIs0, ps[i].lo, ps[i].hi, ps[i].liq, spot, far
                )
                : DepthMath.absorbable(p.s.collateralIs0, ps[i].lo, ps[i].hi, ps[i].liq, near, far);
        }
    }

    function _sell(Params memory p, PoolKey memory key, int24 far, Result memory r) internal {
        uint160 limit = TickMath.getSqrtPriceAtTick(far);
        BalanceDelta d = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: p.s.collateralIs0, amountSpecified: -1e30, sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        r.grossMeasured = uint256(uint128(-(p.s.collateralIs0 ? d.amount0() : d.amount1())));
        (uint160 sqrtAfter,,,) = pm.getSlot0(key.toId());
        r.reachedLimit = sqrtAfter == limit;
    }

    function _collectFees(Params memory p, PoolKey memory key, Pos[] memory ps)
        internal
        returns (uint256 total)
    {
        for (uint256 i; i < ps.length; ++i) {
            BalanceDelta f = liqRouter.modifyLiquidity(
                key, ModifyLiquidityParams(ps[i].lo, ps[i].hi, 0, ps[i].salt), ""
            );
            total += uint256(uint128(p.s.collateralIs0 ? f.amount0() : f.amount1()));
        }
    }

    function _run(
        Scenario memory s,
        uint16 bps,
        uint24 lpFee,
        uint16 protocolFee,
        uint256 seed,
        uint256 n,
        bool live
    ) internal returns (Result memory) {
        return _run(Params(s, bps, lpFee, protocolFee, seed, n, live));
    }

    function _run(Params memory p) internal returns (Result memory r) {
        (PoolKey memory key, uint160 spot) = _initPool(p);
        Pos[] memory ps = _positions(p.seed, p.s.startTick, p.n);
        r.positions = p.n;
        for (uint256 i; i < ps.length; ++i) {
            liqRouter.modifyLiquidity(
                key,
                ModifyLiquidityParams(ps[i].lo, ps[i].hi, int256(uint256(ps[i].liq)), ps[i].salt),
                ""
            );
        }
        int24 far;
        (r.expected, far) = _expectedDepth(p, ps, spot);
        _sell(p, key, far, r);

        uint256 lpFeesCollected = _collectFees(p, key, ps);
        uint256 protoFees =
            pm.protocolFeesAccrued(p.s.collateralIs0 ? key.currency0 : key.currency1);
        r.netMeasured = r.grossMeasured - lpFeesCollected - protoFees;

        (,, uint24 packedProto, uint24 lp) = pm.getSlot0(key.toId());
        r.swapFee = DepthMath.effectiveSwapFee(packedProto, lp, p.s.collateralIs0);
        r.grossUpOfExpected = r.expected == 0 ? 0 : DepthMath.grossUp(r.expected, r.swapFee);
    }

    function _check(Result memory r, string memory tag) internal {
        assertTrue(
            r.reachedLimit, string.concat(tag, ": swap must stop exactly at the far-edge limit")
        );
        assertLe(
            r.expected, r.netMeasured, string.concat(tag, ": DepthMath must never overstate depth")
        );
        uint256 tol = 4 * (r.positions + 1) + 4;
        emit log_named_uint(string.concat(tag, " understatement(wei)"), r.netMeasured - r.expected);
        assertLe(
            r.netMeasured - r.expected,
            tol,
            string.concat(tag, ": understatement within rounding bound")
        );
        assertLe(
            r.grossUpOfExpected,
            r.grossMeasured + tol,
            string.concat(tag, ": gross-up must not overstate the input")
        );
    }

    function _grid(bool live) internal {
        Scenario[] memory all = Scenarios.all();
        for (uint256 i; i < all.length; ++i) {
            for (uint256 f; f < lpFees.length; ++f) {
                for (uint256 p; p < protocolFees.length; ++p) {
                    uint256 snap = vm.snapshotState();
                    Result memory r = _run(
                        all[i],
                        750,
                        lpFees[f],
                        protocolFees[p],
                        (live ? 7000 : 0) + 1000 * i + 10 * f + p,
                        3,
                        live
                    );
                    string memory tag = string.concat(
                        live ? "live " : "anchor ",
                        "scenario ",
                        vm.toString(i),
                        " fee ",
                        vm.toString(f),
                        " proto ",
                        vm.toString(p)
                    );
                    _check(r, tag);
                    if (!live) assertGt(r.expected, 0, "grid case should have depth");
                    vm.revertToState(snap);
                }
            }
        }
    }

    /// @notice Exhaustive grid: every decimals/ordering scenario x every LP fee x every protocol fee, anchor band.
    /// @custom:requirement R-VIEW-1 R-VIEW-2
    /// @custom:invariant INV-9
    function test_Differential_Grid_AnchorBand() public {
        _grid(false);
    }

    /// @notice Same grid from the exact current price (live depth), spot strictly inside a tick.
    /// @custom:requirement R-VIEW-2
    /// @custom:invariant INV-9
    function test_Differential_Grid_LiveDepth() public {
        _grid(true);
    }

    /// forge-config: default.fuzz.runs = 150
    /// forge-config: ci.fuzz.runs = 1000
    /// @custom:requirement R-VIEW-1 R-VIEW-2
    /// @custom:invariant INV-9
    function testFuzz_Differential_AnchorBand(
        uint8 scen,
        uint16 bps,
        uint8 feeSel,
        uint8 protoSel,
        uint256 seed,
        uint8 n
    ) public {
        Scenario[] memory all = Scenarios.all();
        Result memory r = _run(
            Params(
                all[scen % all.length],
                uint16(bound(bps, 100, 2500)),
                lpFees[feeSel % 3],
                protocolFees[protoSel % 3],
                seed,
                bound(n, 1, 4),
                false
            )
        );
        _check(r, "fuzz anchor");
    }

    /// forge-config: default.fuzz.runs = 150
    /// forge-config: ci.fuzz.runs = 1000
    /// @custom:requirement R-VIEW-2
    /// @custom:invariant INV-9
    function testFuzz_Differential_LiveDepth(
        uint8 scen,
        uint16 bps,
        uint8 feeSel,
        uint8 protoSel,
        uint256 seed,
        uint8 n
    ) public {
        Scenario[] memory all = Scenarios.all();
        Result memory r = _run(
            Params(
                all[scen % all.length],
                uint16(bound(bps, 100, 2500)),
                lpFees[feeSel % 3],
                protocolFees[protoSel % 3],
                seed,
                bound(n, 1, 4),
                true
            )
        );
        _check(r, "fuzz live");
    }
}
