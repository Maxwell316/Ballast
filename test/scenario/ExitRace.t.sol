// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StressDriver} from "../utils/StressDriver.sol";
import {Matrix, C0Before, C1After} from "../utils/Matrix.sol";
import {IBallastErrors} from "../../src/interfaces/IBallastErrors.sol";
import {LockState} from "../../src/types/Types.sol";

/// @notice T18, quantified. A ticket that is already mature when a crash begins can leave before the lock engages: the
/// short TWAP lags the spot, so for a few minutes after the crash swap the machine is still CALM. This test measures
/// (1) how much liquidity can leave, as a function of the matured fraction of the shares, (2) how long the window is, and
/// (3) that a ticket requested at the moment of the crash cannot use it. The result is a number with its assumptions.
/// @dev Assumptions, all of the fixture: one vault over [-12000, 12000] with liquidity 1e19; compressed windows (short
/// TWAP 300 s, evaluation interval 60 s, notice 600 s, enter threshold 300 bps = about 305 ticks); a crash of 3.2e17
/// collateral that moves the price about 630 ticks (about 6%), swap fee 0.3%. The bound is structural, not fixture
/// specific: what can leave is exactly the matured share of the supply at the onset (a depositor cannot exit more than
/// they hold), and the lens shows it beforehand, because `liveDepth` nets matured tickets (the mitigation of T18).
/// @custom:guarantee G-4
/// @custom:requirement R-STR-4 R-VIEW-2
abstract contract ExitRaceBase is StressDriver, Matrix {
    function _liq() internal view returns (uint128) {
        return lens.positionsOf(1)[0].liquidity;
    }

    function _setUpRace() internal {
        lensAfterInit = _lensAfter();
        _setUpStressSide(1 hours, _c0());
    }

    /// @notice What can leave in the race window equals the matured fraction of the shares, for any fraction: 10%, 50% and
    /// 90% of the supply. Measured as the fall in the vault's pool liquidity right after the crash swap.
    function test_ExitRace_LiquidityThatCanLeaveEqualsTheMaturedFraction() public {
        _setUpRace();
        uint256 base = vm.snapshotState();
        uint256[3] memory percent = [uint256(10), 50, 90];
        for (uint256 i; i < percent.length; ++i) {
            assertTrue(vm.revertToState(base));
            base = vm.snapshotState();
            uint256 shares = percent[i] * 1e18 / 100; // the supply is 1e18 (INITIAL_SHARES, minimum included)
            uint256 id = vaults.requestRedeem(1, uint128(shares));
            _warmUp(); // 64 minutes: the ticket is mature, and the oracle is warm
            uint128 before_ = _liq();
            uint256 lensView = lens.liveDepth(750, 0);
            uint256 full = lens.poolAbsorbable(750);
            _crash();
            assertEq(
                uint8(_stored()),
                uint8(LockState.CALM),
                "the crash swap alone has not engaged the lock"
            );
            vaults.claimRedeem(id, address(this));
            uint128 left = before_ - _liq();
            emit log_named_uint("T18 matured share of the supply (percent)", percent[i]);
            emit log_named_uint(
                "T18 liquidity that left before the lock engaged (ppm of the vault)",
                uint256(left) * 1e6 / before_
            );
            assertApproxEqRel(
                left, uint256(before_) * percent[i] / 100, 1e15, "exactly the matured fraction"
            );
            // The lender saw it coming: liveDepth already netted the matured ticket.
            assertApproxEqRel(
                lensView, full * (100 - percent[i]) / 100, 1e15, "liveDepth showed the matured exit"
            );
        }
    }

    /// @notice The window is short and a ticket requested at the onset cannot use it: the lock engages within a few
    /// evaluation intervals, long before the notice period ends.
    function test_ExitRace_TheWindowIsShort_AndALateTicketIsBlocked() public {
        _setUpRace();
        _warmUp();
        _crash();
        uint256 late = vaults.requestRedeem(1, 1e16); // requested at the crash: mature 600 s later
        uint256 steps = _stepUntil(LockState.STRESS, 20);
        emit log_named_uint(
            "T18 seconds from the crash to the lock (60 s evaluation steps)", steps * 60
        );
        assertEq(uint8(_stored()), uint8(LockState.STRESS));
        assertLt(steps * 60, 600, "the lock engages before a ticket requested at the crash matures");
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.expectPartialRevert(IBallastErrors.StressLockActive.selector);
        vaults.claimRedeem(late, address(this));
    }
}

contract ExitRaceTest_C0Before is ExitRaceBase, C0Before {}

contract ExitRaceTest_C1After is ExitRaceBase, C1After {}
