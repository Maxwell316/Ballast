// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {StressDriver} from "../../utils/StressDriver.sol";
import {LockState, StressInfo} from "../../../src/types/Types.sol";

/// @notice The stress machine wired into the real hook: lazy evaluation in `beforeSwap`, `pokeStress`, the pure
/// preview in views, and the events (R-STR-1..7).
/// @custom:requirement R-STR-1 R-STR-2 R-STR-3 R-STR-4 R-STR-5 R-STR-6 R-STR-7
contract StressEvaluationTest is StressDriver {
    function test_ColdOracle_StaysCalm_EvenAfterACrash() public {
        _setUpStress(1 hours);
        _crash();
        for (uint256 i; i < 5; ++i) {
            _step(60);
        }
        assertEq(uint8(_stored()), uint8(LockState.CALM), "R-STR-6: no stress while cold");
        StressInfo memory si = hook.stressInfo();
        assertFalse(si.oracleWarm);
        assertFalse(si.lockActive);
    }

    function test_Crash_EntersStress_EventOnce_AndViewPreviewsWithoutWriting() public {
        _setUpStress(1 hours);
        _warmUp();
        assertEq(uint8(_stored()), uint8(LockState.CALM));
        _crash();
        // Let the short TWAP absorb the fall without any swap (and so without an evaluation).
        vm.warp(block.timestamp + 200);
        assertEq(uint8(_stored()), uint8(LockState.CALM), "nothing evaluated yet");
        (LockState previewed, uint40 until) = hook.lockState();
        assertEq(
            uint8(previewed), uint8(LockState.STRESS), "view previews the transition (R-STR-7)"
        );
        assertEq(until, uint40(block.timestamp) + 1 hours, "lock ends maxStressLock after now");
        assertEq(uint8(_stored()), uint8(LockState.CALM), "view did not write");

        vm.recordLogs();
        hook.pokeStress();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(uint8(_stored()), uint8(LockState.STRESS));
        assertEq(_count(logs, SIG_ENTERED), 1, "StressEntered once");
        StressInfo memory si = hook.stressInfo();
        assertTrue(si.lockActive);
        assertTrue(si.oracleWarm);
        assertEq(si.stressStartedAt, uint40(block.timestamp));

        // A second poke in the same state emits nothing.
        vm.recordLogs();
        hook.pokeStress();
        assertEq(vm.getRecordedLogs().length, 0, "no event without a transition");
    }

    function test_FullEpisode_StressRecoveringCalm_EachEventOnce_NoExpiry() public {
        _setUpStress(1 hours);
        _warmUp();
        vm.recordLogs();
        _crash();
        uint256 n = _stepUntil(LockState.STRESS, 20);
        assertLt(n, 20, "enters stress");
        n = _stepUntil(LockState.RECOVERING, 80);
        assertLt(n, 80, "recovers as the anchor catches up");
        assertTrue(hook.stressInfo().lockActive, "RECOVERING still locks");
        n = _stepUntil(LockState.CALM, 40);
        assertLt(n, 40, "calm after calmDuration");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, SIG_ENTERED), 1);
        assertEq(_count(logs, SIG_RECOVERING), 1);
        assertEq(_count(logs, SIG_EXITED), 1);
        assertEq(_count(logs, SIG_EXPIRED), 0, "the episode ended before the lock expired");
        StressInfo memory si = hook.stressInfo();
        assertFalse(si.lockActive);
        assertEq(si.stressStartedAt, 0, "timers cleared in CALM");
    }

    /// @notice Collateral as currency1: liquidations push the tick UP; the same machine, mirrored (R-STR-1).
    function test_CollateralIsCurrency1_FullEpisode_MirroredDirection() public {
        _setUpStressSide(1 hours, false);
        _warmUp();
        vm.recordLogs();
        int24 before_ = _tick();
        _crash();
        assertGt(_tick(), before_ + 400, "selling collateral raised the tick");
        assertLt(_stepUntil(LockState.STRESS, 20), 20);
        assertLt(_stepUntil(LockState.RECOVERING, 80), 80);
        assertLt(_stepUntil(LockState.CALM, 40), 40);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, SIG_ENTERED), 1);
        assertEq(_count(logs, SIG_EXITED), 1);
    }

    /// @notice The mirror image of the above: a fall of the tick when collateral is currency1 is NOT the liquidation
    /// direction and must not enter stress.
    function test_CollateralIsCurrency1_TickFall_DoesNotEnterStress() public {
        _setUpStressSide(1 hours, false);
        _warmUp();
        _swap(false, CRASH); // buy collateral with quote: tick falls when collateral is currency1
        assertLt(_tick(), -400);
        for (uint256 i; i < 10; ++i) {
            _step(60);
        }
        assertEq(uint8(_stored()), uint8(LockState.CALM));
    }

    function test_LockExpiry_EmitsOnce_DoesNotRearm_AndNewEpisodeAfterCalm() public {
        _setUpStress(30 minutes);
        _warmUp();
        vm.recordLogs();
        _crash();
        _stepUntil(LockState.STRESS, 20);
        uint40 started = hook.stressStorage().stressStartedAt;
        assertTrue(hook.stressInfo().lockActive);

        // Run past the maximum lock while the market stays displaced.
        while (block.timestamp < started + 30 minutes + 120) _step(60);
        StressInfo memory si = hook.stressInfo();
        assertFalse(si.lockActive, "lock expired (G-3)");
        assertEq(si.lockedUntil, 0);
        assertTrue(
            uint8(si.state) != uint8(LockState.CALM), "state is not CALM yet: no re-arm possible"
        );
        assertEq(si.stressStartedAt, started, "start unchanged");

        // A relapse (new crash) after expiry must not re-arm the lock (R-STR-5, D-6).
        _crash();
        for (uint256 i; i < 6; ++i) {
            _step(60);
        }
        si = hook.stressInfo();
        assertFalse(si.lockActive, "no re-arm without an intervening CALM");
        assertEq(si.stressStartedAt, started);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, SIG_EXPIRED), 1, "LockExpired exactly once");

        // Back to CALM, then a fresh crash starts a new, active episode.
        _stepUntil(LockState.CALM, 300);
        assertEq(uint8(_stored()), uint8(LockState.CALM));
        assertFalse(hook.stressStorage().lockExpiryRecorded, "flag cleared in CALM");
        _crash();
        _stepUntil(LockState.STRESS, 30);
        assertEq(uint8(_stored()), uint8(LockState.STRESS));
        assertTrue(hook.stressInfo().lockActive, "a new episode locks again");
        assertGt(hook.stressStorage().stressStartedAt, started);
    }

    /// @notice In the liquidation direction only: a rise in the collateral price never enters stress (R-STR-1).
    function test_PriceRiseAgainstLiquidationDirection_DoesNotEnterStress() public {
        _setUpStress(1 hours);
        _warmUp();
        _swap(false, CRASH); // buy collateral with quote: the same size moves the tick by about +630
        assertGt(_tick(), 500, "the price really rose");
        for (uint256 i; i < 10; ++i) {
            _step(60);
        }
        assertEq(uint8(_stored()), uint8(LockState.CALM));
    }

    function test_Evaluation_RunsAtMostOncePerInterval_InBeforeSwap() public {
        _setUpStress(1 hours);
        _warmUp();
        _crash();
        vm.warp(block.timestamp + 200);
        // First swap after the interval: evaluates (and writes a snapshot).
        _swap(false, TINY);
        assertEq(uint8(_stored()), uint8(LockState.STRESS));
        uint256 len = hook.obsLength();
        // A swap 10 s later is inside the snapshot interval: no snapshot, no evaluation.
        vm.warp(block.timestamp + 10);
        _swap(false, TINY);
        assertEq(hook.obsLength(), len, "no snapshot inside the interval");
    }

    /// @notice `pokeStress` makes the oracle progress during swap droughts and is permissionless.
    function test_PokeStress_AdvancesOracle_Permissionless() public {
        _setUpStress(1 hours);
        _warmUp();
        uint256 len = hook.obsLength();
        vm.warp(block.timestamp + 500);
        vm.prank(address(0xBEEF));
        hook.pokeStress();
        assertEq(hook.obsLength(), len + 1, "poke wrote a snapshot");
        assertEq(hook.obsState().lastSwapTs, uint40(block.timestamp));
    }
}
