// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BandMath} from "../../../src/libraries/BandMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Matrix, C0Before, C0After, C1Before, C1After} from "../../utils/Matrix.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {Position, Range} from "../../../src/types/Types.sol";

/// @notice The lens depth views against independent expected values, over both collateral orderings and both lens
/// construction orders (Matrix): committed depth is `min(D_v, commitment)` of the anchor band and static in spot; live
/// depth is measured from spot and so moves with it; previews equal what execution transfers.
/// @dev Expected values: `VECTOR` below (closed form, evaluated off-chain, see `SupplyCapAdvisor.t.sol`), real swaps
/// through plain pools (BruteForce), and the tokens actually moved by execution. Never the lens, the vaults or
/// `DepthMath`.
/// @custom:requirement R-VIEW-1 R-VIEW-2 R-VIEW-4
abstract contract LensDepthBase is Matrix {
    using StateLibrary for IPoolManager;

    /// @dev floor(1e19 x (1.0001^389.5 - 1)): committed depth of liquidity 1e19 over [-6000, 6000], anchor tick 0,
    /// 750 bps (779 ticks), either ordering.
    uint256 internal constant VECTOR = 397_164_717_108_464_068;
    uint256 internal constant VECTOR_TOL = 4;

    function setUp() public {
        _setUpMatrix(ConfigFixture.compressed(), 0);
    }

    function _r(int24 lo, int24 hi) internal pure returns (Range memory) {
        return Range(lo, hi);
    }

    function _seed1(uint256 v, uint128 liq) internal {
        uint128[] memory l = new uint128[](1);
        l[0] = liq;
        vaults.seed(v, l, type(uint128).max, type(uint128).max, address(this));
    }

    function _create(int24 lo, int24 hi, uint128 commitment) internal returns (uint256) {
        Range[] memory r = new Range[](1);
        r[0] = _r(lo, hi);
        return vaults.createVault(r, commitment, 0);
    }

    function test_UnseededVaultCountsNothing_AndPreviewsAreZero() public {
        uint256 v = _create(-6000, 6000, 1e17);
        assertEq(lens.committedDepth(), 0);
        assertEq(lens.liveDepth(750, 0), 0);
        (uint128 a0, uint128 a1) = lens.previewDeposit(v, 1e15);
        assertEq(a0 + a1, 0);
        (a0, a1) = lens.previewRedeem(v, 1e15);
        assertEq(a0 + a1, 0);
    }

    /// @notice `committedDepth` sums `min(D_v, commitment_v)`: the commitment for the first vault, the depth for the
    /// second (whose commitment is above its depth but not yet in breach).
    function test_CommittedDepth_IsMinOfDepthAndCommitment() public {
        uint256 low = _create(-6000, 6000, 1e16);
        uint256 high = _create(-6000, 6000, 9e17);
        _seed1(low, 1e19);
        _seed1(high, 1e19);
        assertApproxEqAbs(lens.vaultDepth(low), VECTOR, VECTOR_TOL, "vault depth is the vector");
        assertApproxEqAbs(lens.vaultDepth(high), VECTOR, VECTOR_TOL);
        assertApproxEqAbs(
            lens.committedDepth(), 1e16 + VECTOR, VECTOR_TOL, "K for the first, D for the second"
        );
    }

    /// @notice Committed depth is static in spot (it depends on ranges and the anchor); live depth is measured from
    /// the current spot, so it moves, and here it RISES after a sale because more collateral sits per tick at the
    /// new price. It is not "what remains of an earlier number" (docs/CONTRACTS.md, consumer guidance).
    function test_CommittedDepthIsStaticInSpot_LiveDepthMovesWithIt() public {
        uint256 v = _create(-6000, 6000, 1e17);
        _seed1(v, 1e19);
        vm.warp(vm.getBlockTimestamp() + 300); // the anchor TWAP is defined, and equals tick 0
        uint256 liveBefore = lens.liveDepth(750, 0);
        assertApproxEqAbs(liveBefore, VECTOR, VECTOR_TOL);

        _swap(true, 5e17); // sells half a unit of collateral: the price moves about 1,000 ticks in the liquidation direction
        int24 spot = _tick();
        assertGt(int256(spot) * int256(_liquidationSign()), 900, "the price moved with the sale");
        assertEq(hook.stressInfo().anchorTick, 0, "the anchor did not follow the sale");

        assertApproxEqAbs(lens.vaultDepth(v), VECTOR, VECTOR_TOL, "committed depth is unchanged");
        uint256 liveAfter = lens.liveDepth(750, 0);
        assertGt(
            liveAfter, liveBefore, "live depth is a measure from the new spot, not a remainder"
        );

        Position[] memory ps = new Position[](1);
        ps[0] = Position(-6000, 6000, 1e19);
        (uint160 sqrtP,,,) = IPoolManager(address(pm)).getSlot0(pid);
        Plain memory p = _plainPool(ps, sqrtP, cfg.fee, 0);
        (uint256 narrow, uint256 wide,) = _absorbTwoStage(p, _farEdge(spot, 750));
        assertLe(liveAfter, wide, "never above the measured absorbable collateral at the new spot");
        assertGe(liveAfter + tolerance(1), narrow, "and tight to it");
    }

    // ─── exact floors: the rounding direction, to the wei ───

    /// @dev Absorbable collateral between two sqrt prices, floored, evaluated with the integer order of
    /// `SqrtPriceMath` written out here: token0 `floor(floor(L * 2^96 * (b - a) / b) / a)`, token1
    /// `floor(L * (b - a) / 2^96)`. A swap comparison cannot see a one-wei rounding error (the swap itself rounds
    /// up), so these tests pin the direction exactly.
    function _exactFloor(uint160 a, uint160 b, uint128 liq) internal view returns (uint256) {
        return collateralIs0
            ? FullMath.mulDiv(uint256(liq) << 96, b - a, b) / a
            : FullMath.mulDiv(liq, b - a, 1 << 96);
    }

    function _exactBand(uint160 sqrtNear, int24 nearTick, uint128 liq, uint16 bps)
        internal
        returns (uint256)
    {
        uint160 sqrtFar = TickMath.getSqrtPriceAtTick(_farEdge(nearTick, bps));
        return
            collateralIs0
                ? _exactFloor(sqrtFar, sqrtNear, liq)
                : _exactFloor(sqrtNear, sqrtFar, liq);
    }

    function _pinBand() internal {
        assertEq(int256(_tableTicks(750)), 779, "table value for 750 bps");
        assertEq(
            BandMath.bpsToTicksDown(750), 779, "BandMath agrees for 750 bps, so one edge applies"
        );
    }

    function test_VaultDepthAndLiveDepth_AreTheExactFloor() public {
        _pinBand();
        uint256 v = _create(-6000, 6000, 1e17);
        _seed1(v, 1e19);
        uint256 exact = _exactBand(TickMath.getSqrtPriceAtTick(0), 0, 1e19, 750);
        assertApproxEqAbs(exact, VECTOR, VECTOR_TOL, "the exact floor is the vector");
        assertEq(lens.vaultDepth(v), exact, "committed depth rounds down exactly");
        assertEq(lens.liveDepth(750, 0), exact, "live depth rounds down exactly");
        assertEq(lens.poolAbsorbable(750), exact, "pool-wide depth rounds down exactly");
    }

    function test_LiveDepth_AfterSpotMoves_IsTheExactFloor() public {
        _pinBand();
        uint256 v = _create(-6000, 6000, 1e17);
        _seed1(v, 1e19);
        _swap(true, 5e17);
        (uint160 sqrtP, int24 spot,,) = IPoolManager(address(pm)).getSlot0(pid);
        assertEq(
            lens.liveDepth(750, 0),
            _exactBand(sqrtP, spot, 1e19, 750),
            "from the exact spot price (not the tick), rounded down exactly"
        );
    }

    function test_LiveDepth_ExitNetting_IsTheExactFloor() public {
        _pinBand();
        uint256 v = _create(-6000, 6000, 1e17);
        _seed1(v, 1e19);
        vaults.requestRedeem(v, 2e17);
        uint256 exact = _exactBand(TickMath.getSqrtPriceAtTick(0), 0, 1e19, 750);
        assertEq(
            lens.liveDepth(750, 600),
            FullMath.mulDiv(exact, 8e17, 1e18),
            "depth x (supply - exiting) / supply, rounded down exactly"
        );
    }

    // ─── previews equal execution, with positions below, across and above spot ───

    function _threeRangeVault() internal returns (uint256 v) {
        Range[] memory r = new Range[](3);
        r[0] = _r(-6000, -3000);
        r[1] = _r(-1200, 1200);
        r[2] = _r(3000, 6000);
        v = vaults.createVault(r, 0, 0);
        uint128[] memory l = new uint128[](3);
        l[0] = 3e18;
        l[1] = 5e18;
        l[2] = 4e18;
        vaults.seed(v, l, type(uint128).max, type(uint128).max, address(this));
    }

    function _balances() internal view returns (uint256 c, uint256 q) {
        return (collateral.balanceOf(address(this)), quote.balanceOf(address(this)));
    }

    function test_PreviewDeposit_EqualsWhatExecutionPays() public {
        uint256 v = _threeRangeVault();
        (uint128 p0, uint128 p1) = lens.previewDeposit(v, 3e17);
        (uint256 c0, uint256 q0) = _balances();
        vaults.deposit(v, 3e17, type(uint128).max, type(uint128).max, address(this));
        (uint256 c1, uint256 q1) = _balances();
        (uint256 paid0, uint256 paid1) = collateralIs0 ? (c0 - c1, q0 - q1) : (q0 - q1, c0 - c1);
        assertEq(p0, paid0, "currency0 paid");
        assertEq(p1, paid1, "currency1 paid");
    }

    function test_PreviewRedeem_EqualsWhatExecutionReturns() public {
        uint256 v = _threeRangeVault();
        (uint128 p0, uint128 p1) = lens.previewRedeem(v, 2e17);
        uint256 t = vaults.requestRedeem(v, 2e17);
        vm.warp(vm.getBlockTimestamp() + 600);
        (uint256 c0, uint256 q0) = _balances();
        vaults.claimRedeem(t, address(this));
        (uint256 c1, uint256 q1) = _balances();
        (uint256 got0, uint256 got1) = collateralIs0 ? (c1 - c0, q1 - q0) : (q1 - q0, c1 - c0);
        assertEq(p0, got0, "currency0 returned");
        assertEq(p1, got1, "currency1 returned");
    }
}

contract LensDepthTest_C0Before is LensDepthBase, C0Before {}

contract LensDepthTest_C0After is LensDepthBase, C0After {}

contract LensDepthTest_C1Before is LensDepthBase, C1Before {}

contract LensDepthTest_C1After is LensDepthBase, C1After {}
