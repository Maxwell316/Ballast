// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StressDriver} from "../utils/StressDriver.sol";
import {IBallastErrors} from "../../src/interfaces/IBallastErrors.sol";
import {LockState, Range, StressInfo, TicketView} from "../../src/types/Types.sol";

/// @notice The stress gate end to end through the vaults: a crash engages the lock, a liquidation-sized sell still
/// executes against the committed liquidity, exits and re-ranges are refused while the lock is active, the lock
/// releases at calm or at `maxStressLock`, and the exit race at crash onset is visible (M5; R-STR-3..9, G-3, T18).
/// @dev Fixture: one seeded vault (id 1, held by this contract) over [-12000, 12000] with liquidity 1e19; compressed
/// windows (anchor 1 h, short 5 min, interval 60 s, calm 10 min, notice 10 min).
/// @custom:guarantee G-3 G-4
/// @custom:requirement R-STR-4 R-STR-7 R-VLT-2 R-VLT-8 R-VLT-14
contract CrashTest is StressDriver {
    uint256 internal constant LIQUIDATION = 4e17;
    uint256 internal v = 1;
    uint256 internal unseeded;
    uint256 internal matured; // a ticket that is mature before any crash

    function _setUpCrash(uint32 maxStressLock) internal {
        _setUpStress(maxStressLock);
        Range[] memory r = new Range[](1);
        r[0] = Range(-6000, 6000);
        unseeded = vaults.createVault(r, 0, 0);
        matured = vaults.requestRedeem(v, 1e17);
        _warmUp(); // 64 minutes: the ticket is long mature
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

    function test_Liquidation_ExecutesInStress_AndLiveDepthFallsWhileTheLockHolds() public {
        _setUpCrash(1 hours);
        _toStress();
        uint256 depthBefore = lens.poolAbsorbable(750);
        assertGt(depthBefore, 0);
        uint256 q0 = quote.balanceOf(address(this));
        _swap(true, LIQUIDATION);
        assertGt(quote.balanceOf(address(this)), q0, "liquidator was paid by the committed liquidity");
        assertLt(lens.poolAbsorbable(750), depthBefore, "the sell consumed depth");
        // The liquidity that served it was still locked in the pool throughout.
        _expectLocked();
        vaults.claimRedeem(matured, address(this));
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

    // ─── horizon netting around the lock ───

    function test_LiveDepth_NetsExitsThatCannotBeBlocked_ButNotOnesTheLockHolds() public {
        _setUpCrash(1 hours);
        // CALM: the matured ticket (10% of shares) can leave at any moment, so any horizon nets it.
        uint256 full = lens.poolAbsorbable(750);
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
