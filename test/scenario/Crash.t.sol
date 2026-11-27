// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StressDriver} from "../utils/StressDriver.sol";
import {Matrix, C0Before, C0After, C1Before, C1After} from "../utils/Matrix.sol";
import {BandMath} from "../../src/libraries/BandMath.sol";
import {Position} from "../../src/types/Types.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IBallastErrors} from "../../src/interfaces/IBallastErrors.sol";
import {LockState, Range, StressInfo, TicketView} from "../../src/types/Types.sol";

/// @notice The stress gate end to end through the vaults: a crash engages the lock, a liquidation-sized sell still
/// executes against the committed liquidity, exits and re-ranges are refused while the lock is active, the lock
/// releases at calm or at `maxStressLock`, and the exit race at crash onset is visible (M5; R-STR-3..9, G-3, T18).
/// @dev Fixture: one seeded vault (id 1, held by this contract) over [-12000, 12000] with liquidity 1e19; compressed
/// windows (anchor 1 h, short 5 min, interval 60 s, calm 10 min, notice 10 min).
/// @custom:guarantee G-3 G-4
/// @custom:requirement R-STR-4 R-STR-7 R-VLT-2 R-VLT-8 R-VLT-14
abstract contract CrashBase is StressDriver, Matrix {
    using StateLibrary for IPoolManager;

    uint256 internal constant LIQUIDATION = 4e17;
    uint256 internal v = 1;
    uint256 internal unseeded;
    uint256 internal matured; // a ticket that is mature before any crash

    function _setUpCrash(uint32 maxStressLock) internal {
        lensAfterInit = _lensAfter();
        _setUpStressSide(maxStressLock, _c0());
        Range[] memory r = new Range[](1);
        r[0] = Range(-6000, 6000);
        unseeded = vaults.createVault(r, 0, 0);
        matured = vaults.requestRedeem(v, 1e17);
        _warmUp(); // 64 minutes: the ticket is long mature
    }

    /// @dev Crash tests build their fixture inside each test, so the matrix variant check sets one up first.
    function test_Crash_VariantIsWhatItClaims() public {
        _setUpCrash(1 hours);
        _assertVariant();
    }

    function _toStress() internal {
        _crash();
        _stepUntil(LockState.STRESS, 20);
        assertEq(uint8(_stored()), uint8(LockState.STRESS));
    }

    function _liq(uint256 id) internal view returns (uint128) {
        return lens.positionsOf(id)[0].liquidity;
    }

    function _expectLocked() internal {
        vm.expectPartialRevert(IBallastErrors.StressLockActive.selector);
    }

    // ─── the gate ───

    function test_Stress_BlocksExitsDepositsSeedsAndReranges_ButNotRequestsOrCancels() public {
        _setUpCrash(1 hours);
        _toStress();
        uint128 before_ = _liq(v);

        _expectLocked();
        vaults.claimRedeem(matured, address(this));
        _expectLocked();
        vaults.deposit(v, 1e15, type(uint128).max, type(uint128).max, address(this));
        uint128[] memory l = new uint128[](1);
        l[0] = 1e18;
        _expectLocked();
        vaults.seed(unseeded, l, type(uint128).max, type(uint128).max, address(this));
        Range[] memory r = new Range[](1);
        r[0] = Range(-6000, 6000);
        _expectLocked();
        vaults.rerange(v, r, l);
        assertEq(_liq(v), before_, "no liquidity left the pool (INV-6)");

        // Requests, cancels and bookkeeping are not exits and stay available.
        uint256 t2 = vaults.requestRedeem(v, 1e15);
        vaults.cancelRedeem(t2);
        vaults.checkpoint(v);
        vaults.setCommitment(v, 1);
        vaults.claimCuratorFees(v, address(this));
    }

    function test_Recovering_StillLocks_UntilCalm() public {
        _setUpCrash(1 hours);
        _toStress();
        _stepUntil(LockState.RECOVERING, 80);
        assertEq(uint8(_stored()), uint8(LockState.RECOVERING));
        _expectLocked();
        vaults.claimRedeem(matured, address(this));
    }

    function test_Calm_ReleasesExitsAndReopensDeposits() public {
        _setUpCrash(2 hours);
        _toStress();
        _stepUntil(LockState.CALM, 200);
        assertEq(uint8(_stored()), uint8(LockState.CALM));
        vaults.claimRedeem(matured, address(this)); // no poke needed (R-STR-7b)
        vaults.deposit(v, 1e15, type(uint128).max, type(uint128).max, address(this));
    }

    /// @notice The lock is bounded: after `maxStressLock` exits work even though the state is not CALM (G-3), while
    /// deposits and re-ranges stay refused outside CALM (they are not exits).
    function test_MaxStressLock_ReleasesExitsEvenIfNotCalm() public {
        _setUpCrash(30 minutes);
        _toStress();
        uint40 started = hook.stressStorage().stressStartedAt;
        while (vm.getBlockTimestamp() < started + 30 minutes - 60) _step(60);
        _expectLocked();
        vaults.claimRedeem(matured, address(this)); // one minute before expiry: still locked
        vm.warp(started + 30 minutes);
        assertFalse(hook.stressInfo().lockActive);
        vaults.claimRedeem(matured, address(this));
        assertEq(lens.ticket(matured).owner, address(0), "the exit went through");
        if (_stored() != LockState.CALM) {
            vm.expectRevert(IBallastErrors.NotCalm.selector);
            vaults.deposit(v, 1e15, type(uint128).max, type(uint128).max, address(this));
        }
    }

    // ─── the product: the liquidation executes against committed liquidity ───

    function test_Liquidation_ExecutesInStress_AndTheLockHolds() public {
        _setUpCrash(1 hours);
        _toStress();
        uint256 depthBefore = lens.poolAbsorbable(750);
        assertGt(depthBefore, LIQUIDATION, "the live depth covers the liquidation-sized sell");
        int24 tickBefore = _tick();
        uint256 q0 = quote.balanceOf(address(this));
        uint256 c0 = collateral.balanceOf(address(this));
        _swap(true, LIQUIDATION);
        assertGt(
            quote.balanceOf(address(this)), q0, "liquidator was paid by the committed liquidity"
        );
        assertEq(
            c0 - collateral.balanceOf(address(this)), LIQUIDATION, "the whole sell was absorbed"
        );
        // Live depth is measured over a window that moves with spot, so it is not monotone under a sell (the same
        // percentage window holds more collateral at a lower price). The consumption shows in the price instead.
        assertGt(
            int256(_tick() - tickBefore) * int256(_liquidationSign()),
            0,
            "the sell moved the price through committed liquidity"
        );
        // The liquidity that served it was still locked in the pool throughout.
        _expectLocked();
        vaults.claimRedeem(matured, address(this));
    }

    // ─── the product, stronger: depth to a FIXED far edge falls by exactly what was sold ───

    /// @notice `liveDepth` is measured from the current spot, so its figure before and after a sale are not directly
    /// comparable (the window moves). Pinning the far edge makes them comparable: the collateral absorbable from the
    /// pre-sale spot to the far edge F, minus what the sale absorbed (net of the swap fee), equals the collateral
    /// absorbable from the post-sale spot to the same F.
    ///
    /// F is the same tick on both sides by construction: a snapshot lets the test sell once to learn how far the spot
    /// moves (`delta` ticks), pick impacts `b0` and `b1` whose conservative tick distances satisfy
    /// `ticks(b0) = delta + ticks(b1)`, revert, and then measure `b0` before and `b1` after a second, identical sale.
    ///
    /// Expected values: the net sold is the closed form `SOLD x (1e6 - fee) / 1e6`; the before figure is also checked
    /// against a brute-force swap on a plain pool (BruteForce). Tolerance, `TOL = 3` wei, one per rounding that can
    /// differ: the lens floors the before figure (1) and the after figure (1), and the swap rounds its net input up
    /// (1). The fee rounding and the one-step price rounding are far below a wei at these sizes. Observed: exactly
    /// zero in all four variants. The identity must hold to the wei, not to a percentage.
    function test_Liquidation_DepthToAFixedFarEdge_FallsByExactlyWhatWasSold() public {
        _setUpCrash(1 hours);
        _toStress();
        uint256 sold = 1e17;
        uint256 snap = vm.snapshotState();

        int24 spot0 = _tick();
        _swap(true, sold);
        uint24 delta = uint24(int24(int256(_tick() - spot0) * int256(_liquidationSign())));
        (uint16 b0, uint16 b1) = _impactsWithDistance(delta);
        assertTrue(b0 != 0, "an impact pair with the required tick difference exists");
        assertTrue(vm.revertToState(snap), "state reverted");

        uint128 liq = _liq(v);
        (uint160 sqrt0, int24 s0,,) = IPoolManager(address(pm)).getSlot0(pid);
        assertEq(s0, spot0, "revert restored the spot");
        uint256 before_ = lens.poolAbsorbable(b0);
        // Independent check of the before figure: a plain pool holding the same position, one real swap to F.
        {
            Position[] memory ps = new Position[](1);
            ps[0] = Position(-12_000, 12_000, liq);
            Plain memory p = _plainPool(ps, sqrt0, cfg.fee, 0);
            (uint256 narrow, uint256 wide,) = _absorbTwoStage(p, _farEdge(spot0, b0));
            assertLe(before_, wide, "before: never above the measured absorbable collateral");
            assertGe(before_ + tolerance(1), narrow, "before: tight to the measured figure");
        }
        _swap(true, sold);
        assertEq(uint24(int24(int256(_tick() - spot0) * int256(_liquidationSign()))), delta);
        uint256 after_ = lens.poolAbsorbable(b1);

        uint256 netSold = sold * (1_000_000 - cfg.fee) / 1_000_000;
        assertApproxEqAbs(before_ - after_, netSold, 3, "before - after = sold, net of the fee");
    }

    /// @dev Finds impacts with `BandMath.bpsToTicksDown(b0) == delta + bpsToTicksDown(b1)`, both in 1..2500.
    /// `BandMath` is used here only to choose the two parameters; the expected values never come from it.
    function _impactsWithDistance(uint24 delta) internal pure returns (uint16 b0, uint16 b1) {
        for (uint16 a = 600; a <= 900; ++a) {
            uint24 ta = BandMath.bpsToTicksDown(a);
            if (ta <= delta) continue;
            for (uint16 b = 100; b < a; ++b) {
                if (BandMath.bpsToTicksDown(b) + delta == ta) return (a, b);
            }
        }
    }

    // ─── T18: the exit race at crash onset ───

    /// @notice A matured ticket exits at crash prices in the window between the crash and the lock engaging: the
    /// short TWAP lags spot, so right after the crash swap the machine is still CALM. After the lag, the same exit is
    /// refused. This is the accepted exposure of T18, quantified by this test.
    function test_ExitRace_MaturedTicketLeavesBeforeTheLockEngages() public {
        _setUpCrash(1 hours);
        _crash(); // price falls; the oracle has not yet seen time pass at the new tick
        assertEq(uint8(_stored()), uint8(LockState.CALM));
        uint128 liqBefore = _liq(v);
        vaults.claimRedeem(matured, address(this));
        uint128 left = liqBefore - _liq(v);
        assertGt(left, 0, "liquidity left in the race window");
        // 1e17 of 1e18 shares: about a tenth of the vault's liquidity.
        assertApproxEqRel(left, liqBefore / 10, 1e16);

        // Once the lag has elapsed the lock engages and the next exit is refused.
        uint256 t2 = vaults.requestRedeem(v, 1e16);
        vm.warp(vm.getBlockTimestamp() + 601);
        _stepUntil(LockState.STRESS, 20);
        _expectLocked();
        vaults.claimRedeem(t2, address(this));
    }

    /// @notice `lockState().lockedUntil` is the informational upper bound `stressStartedAt + maxStressLock` while the
    /// lock is active, zero otherwise; `earliestRelease` (used for netting) is never later (ADR-047).
    /// @custom:requirement R-VIEW-3
    function test_LockState_LockedUntilIsAnUpperBound_EarliestReleaseNeverLater() public {
        _setUpCrash(1 hours);
        (LockState s0, uint40 until0) = hook.lockState();
        assertEq(uint8(s0), uint8(LockState.CALM));
        assertEq(until0, 0);
        _toStress();
        (LockState s1, uint40 until1) = hook.lockState();
        assertEq(uint8(s1), uint8(LockState.STRESS));
        assertEq(until1, hook.stressStorage().stressStartedAt + 1 hours);
        assertLe(hook.stressInfo().earliestRelease, until1);
    }

    /// @notice Inside the lock no ticket can leave, so the lens counts none; past the earliest release the matured
    /// ticket counts (ADR-047).
    function test_ExitingShares_AreZeroInsideTheLock_AndCountedAfterTheEarliestRelease() public {
        _setUpCrash(1 hours);
        assertEq(lens.exitingShares(v, 0), 1e17, "calm: the matured ticket can leave now");
        _toStress();
        assertEq(lens.exitingShares(v, 0), 0, "locked: nothing can leave inside the horizon");
        uint32 untilRelease = uint32(hook.stressInfo().earliestRelease - vm.getBlockTimestamp());
        assertEq(
            lens.exitingShares(v, untilRelease),
            1e17,
            "counted once the horizon reaches the release"
        );
    }

    // ─── horizon netting around the lock ───

    function test_LiveDepth_NetsExitsThatCannotBeBlocked_ButNotOnesTheLockHolds() public {
        _setUpCrash(1 hours);
        // CALM: the matured ticket (10% of shares) can leave at any moment, so any horizon nets it.
        uint256 full = lens.poolAbsorbable(750);
        {
            // The un-netted figure is itself checked against a real swap, so the 90% ratio below applies to an
            // independent number (the ratio is closed form: 1e17 of 1e18 shares exit).
            Position[] memory ps = new Position[](1);
            ps[0] = Position(-12_000, 12_000, _liq(v));
            (uint160 sqrtP, int24 spot,,) = IPoolManager(address(pm)).getSlot0(pid);
            Plain memory p = _plainPool(ps, sqrtP, cfg.fee, 0);
            (uint256 narrow, uint256 wide,) = _absorbTwoStage(p, _farEdge(spot, 750));
            assertLe(full, wide, "poolAbsorbable never exceeds the measured depth");
            assertGe(full + tolerance(1), narrow, "and is tight to it");
        }
        uint256 netNow = lens.liveDepth(750, 0);
        assertApproxEqRel(netNow, full * 9 / 10, 1e16, "10% of the shares are leaving");
        _toStress();
        // STRESS: the earliest release is the calm time (now + calmDuration) or lock expiry, whichever is first.
        StressInfo memory info = hook.stressInfo();
        assertGt(info.earliestRelease, vm.getBlockTimestamp());
        uint256 short_ = lens.liveDepth(750, 0);
        uint256 long_ = lens.liveDepth(750, uint32(info.earliestRelease - vm.getBlockTimestamp()));
        assertGt(short_, long_, "beyond the earliest release the exit is counted");
        assertEq(short_, lens.poolAbsorbable(750), "inside the lock nothing is netted");
    }
}

contract CrashTest_C0Before is CrashBase, C0Before {}

contract CrashTest_C0After is CrashBase, C0After {}

contract CrashTest_C1Before is CrashBase, C1Before {}

contract CrashTest_C1After is CrashBase, C1After {}
