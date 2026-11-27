// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Matrix, C0Before, C0After, C1Before, C1After} from "../../utils/Matrix.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {BallastStandby} from "../../../src/BallastStandby.sol";
import {BandMath} from "../../../src/libraries/BandMath.sol";
import {Position, Range} from "../../../src/types/Types.sol";

/// @notice Standby accrual pays on the smallest of the interval's depth samples (R-SBY-3, ADR-025): when the market
/// eats into a narrow vault, the reward follows the live depth, not the anchor-based depth or the commitment.
/// @dev The expected depth is measured by real swaps through plain pools holding the vault's position (BruteForce),
/// and the reward is the closed form `depth x seconds x rate / 1e18`; neither the lens, the vaults nor `DepthMath`
/// produces an expected value. Run over both collateral orderings and both lens construction orders (Matrix).
/// @custom:requirement R-SBY-3
/// @custom:guarantee G-5
abstract contract StandbySamplingBase is Matrix {
    using StateLibrary for IPoolManager;

    uint128 internal constant RATE = 1e12;
    uint128 internal constant COMMITMENT = 3e17;
    uint16 internal constant BAND_BPS = 750;
    uint128 internal constant LIQ = 2e19;

    BallastStandby internal standby;
    uint256 internal v;

    function setUp() public {
        _setUpMatrix(ConfigFixture.compressed(), 0);
        standby = BallastStandby(address(vaults.standby()));
        Range[] memory r = new Range[](1);
        r[0] = Range(-1200, 1200);
        v = vaults.createVault(r, COMMITMENT, 0);
        uint128[] memory l = new uint128[](1);
        l[0] = LIQ;
        vaults.seed(v, l, type(uint128).max, type(uint128).max, address(this));
        quote.mint(ConfigFixture.SPONSOR, 1e24);
        vm.startPrank(ConfigFixture.SPONSOR);
        quote.approve(address(standby), type(uint256).max);
        standby.fundStandby(1e18);
        standby.setStandbyRate(RATE);
        vm.stopPrank();
    }

    function test_Accrual_UsesTheSmallestSample_WhenLiveDepthFalls() public {
        vaults.checkpoint(v); // first sample: full depth at the start of the interval
        _swap(true, 11e17); // sell collateral into the vault, moving the price in the liquidation direction
        int24 moved = _tick();
        assertGt(int256(moved) * int256(_liquidationSign()), 500, "the market moved into the band");
        vm.warp(vm.getBlockTimestamp() + 100);
        // All elapsed time was spent at the moved tick, so the anchor TWAP is exactly that tick.
        assertEq(hook.stressInfo().anchorTick, moved, "precondition: anchor is the moved tick");
        assertEq(
            int256(uint256(BandMath.bpsToTicksDown(BAND_BPS))),
            int256(_tableTicks(BAND_BPS)),
            "precondition: for 750 bps BandMath equals the table value, so one swap edge applies"
        );

        // Expected samples by brute force, on a plain pool with the vault's one position.
        Position[] memory ps = new Position[](1);
        ps[0] = Position(-1200, 1200, LIQ);
        (uint160 sqrtP, int24 spot,,) = IPoolManager(address(pm)).getSlot0(pid);
        Plain memory live = _plainPool(ps, sqrtP, cfg.fee, 0);
        (, uint256 liveDepth,) = _absorbTwoStage(live, _farEdge(spot, BAND_BPS));
        Plain memory anchored = _plainPool(ps, TickMath.getSqrtPriceAtTick(moved), cfg.fee, 0);
        (, uint256 anchorDepth,) = _absorbTwoStage(anchored, _farEdge(moved, BAND_BPS));
        uint256 expectedDepth = liveDepth < anchorDepth ? liveDepth : anchorDepth;
        if (COMMITMENT < expectedDepth) expectedDepth = COMMITMENT;
        assertLt(expectedDepth, COMMITMENT, "the sample is the binding one, not the commitment");

        uint256 before_ = _idleQuote(v);
        vaults.checkpoint(v);
        uint256 paid = _idleQuote(v) - before_; // zero curator fee: everything goes to idle
        // Closed form; a depth error of d wei moves the reward by d x 1e-4 quote wei, so +-1 covers the allowance.
        assertApproxEqAbs(
            paid, expectedDepth * 100 * RATE / 1e18, 1, "reward follows the smallest sample"
        );
    }
}

contract StandbySamplingTest_C0Before is StandbySamplingBase, C0Before {}

contract StandbySamplingTest_C0After is StandbySamplingBase, C0After {}

contract StandbySamplingTest_C1Before is StandbySamplingBase, C1Before {}

contract StandbySamplingTest_C1After is StandbySamplingBase, C1After {}
