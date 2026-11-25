// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {RewardMath} from "../../../src/libraries/RewardMath.sol";
import {RATE_SCALE} from "../../../src/types/Constants.sol";

contract RewardMathHarness {
    function splitCurator(uint256 a, uint16 f) external pure returns (uint256, uint256) {
        return RewardMath.splitCurator(a, f);
    }
}

/// @notice Unit, fuzz and differential tests for RewardMath. Independent of decimals and collateral ordering: the
/// decimal conversion happens in the sponsor's rate (ECONOMICS §4), not here.
contract RewardMathTest is Test {
    RewardMathHarness internal h = new RewardMathHarness();

    /// @custom:requirement R-SBY-3
    function test_Accrue_Examples() public pure {
        // 1000 depth x 100 s x rate 0.5 (5e17 / 1e18) = 50_000
        assertEq(RewardMath.accrue(1000, 5e17, 100), 50_000);
        // floor: 3 x 1 x 1e17 / 1e18 = 0.3 -> 0
        assertEq(RewardMath.accrue(3, 1e17, 1), 0);
        assertEq(RewardMath.accrue(0, 5e17, 100), 0);
        assertEq(RewardMath.accrue(1000, 0, 100), 0);
        assertEq(RewardMath.accrue(1000, 5e17, 0), 0);
    }

    /// @custom:requirement R-SBY-3
    function test_Accrue_MaximumInputsDoNotOverflow() public pure {
        uint256 r = RewardMath.accrue(type(uint128).max, type(uint128).max, type(uint32).max);
        // Exact reference through FullMath on the 160-bit product.
        uint256 prod = uint256(type(uint128).max) * type(uint32).max;
        assertEq(r, FullMath.mulDiv(prod, type(uint128).max, RATE_SCALE));
        assertLt(r, 1 << 229);
    }

    /// @notice Differential against Uniswap's independent `FullMath`, plus the exact-floor identity
    /// `reward * S <= depth*dt*rate < (reward + 1) * S` checked with mulmod.
    /// @custom:requirement R-SBY-3
    /// @custom:invariant INV-8
    function testFuzz_Accrue_IsExactFloor(uint128 depth, uint128 rate, uint32 dt) public pure {
        uint256 reward = RewardMath.accrue(depth, rate, dt);
        uint256 prod = uint256(depth) * dt;
        assertEq(reward, FullMath.mulDiv(prod, rate, RATE_SCALE));
        // Remainder identity: prod*rate - reward*S is in [0, S). Use mulmod to get (prod*rate) mod S.
        uint256 rem = mulmod(prod, rate, RATE_SCALE);
        assertEq(FullMath.mulDivRoundingUp(prod, rate, RATE_SCALE), rem == 0 ? reward : reward + 1);
    }

    /// @custom:requirement R-SBY-3
    function testFuzz_Accrue_MonotonicInEachArgument(
        uint128 d1,
        uint128 d2,
        uint128 r1,
        uint128 r2,
        uint32 t1,
        uint32 t2
    ) public pure {
        (d1, d2) = d1 <= d2 ? (d1, d2) : (d2, d1);
        (r1, r2) = r1 <= r2 ? (r1, r2) : (r2, r1);
        (t1, t2) = t1 <= t2 ? (t1, t2) : (t2, t1);
        assertLe(RewardMath.accrue(d1, r2, t2), RewardMath.accrue(d2, r2, t2));
        assertLe(RewardMath.accrue(d2, r1, t2), RewardMath.accrue(d2, r2, t2));
        assertLe(RewardMath.accrue(d2, r2, t1), RewardMath.accrue(d2, r2, t2));
    }

    /// @notice Splitting an interval in two never pays more than one combined interval (floors are
    /// superadditive in reverse): a keeper cannot gain by checkpointing often.
    /// @custom:requirement R-SBY-3
    /// @custom:invariant INV-8
    function testFuzz_Accrue_SplittingIntervalNeverPaysMore(
        uint128 depth,
        uint128 rate,
        uint16 t1,
        uint16 t2
    ) public pure {
        uint256 split =
            RewardMath.accrue(depth, rate, t1) + RewardMath.accrue(depth, rate, t2);
        assertLe(split, RewardMath.accrue(depth, rate, uint32(t1) + uint32(t2)));
    }

    /// @custom:requirement R-SBY-3
    function test_AccrualInterval_Cases() public pure {
        assertEq(RewardMath.accrualInterval(100, 40, 3600), 60);
        assertEq(RewardMath.accrualInterval(10_000, 40, 3600), 3600, "capped by maxAccrualInterval");
        assertEq(RewardMath.accrualInterval(40, 40, 3600), 0, "same timestamp");
        assertEq(RewardMath.accrualInterval(39, 40, 3600), 0, "clock before checkpoint");
    }

    /// @custom:requirement R-SBY-3
    function testFuzz_AccrualInterval_NeverExceedsCapOrElapsed(
        uint40 nowTs,
        uint40 last,
        uint32 cap
    ) public pure {
        uint256 i = RewardMath.accrualInterval(nowTs, last, cap);
        assertLe(i, cap);
        if (nowTs > last) assertLe(i, uint256(nowTs) - last);
        else assertEq(i, 0);
    }

    /// @custom:requirement R-SBY-3
    function testFuzz_Eligible_IsMinimumOfThree(uint128 a, uint128 b, uint128 c) public pure {
        uint128 e = RewardMath.eligible(a, b, c);
        assertLe(e, a);
        assertLe(e, b);
        assertLe(e, c);
        assertTrue(e == a || e == b || e == c);
    }

    /// @custom:requirement R-SBY-3
    function test_CapToFund() public pure {
        assertEq(RewardMath.capToFund(10, 100), 10);
        assertEq(RewardMath.capToFund(100, 10), 10);
        assertEq(RewardMath.capToFund(7, 7), 7);
        assertEq(RewardMath.capToFund(5, 0), 0);
    }

    /// @custom:requirement R-SBY-4 R-FEE-2
    function test_SplitCurator_Examples() public pure {
        (uint256 c, uint256 i) = RewardMath.splitCurator(1000, 2000);
        assertEq(c, 200);
        assertEq(i, 800);
        (c, i) = RewardMath.splitCurator(9, 2000); // 1.8 -> 1 to curator, 8 to depositors
        assertEq(c, 1);
        assertEq(i, 8);
        (c, i) = RewardMath.splitCurator(1000, 0);
        assertEq(c, 0);
        assertEq(i, 1000);
        (c, i) = RewardMath.splitCurator(1000, 10_000);
        assertEq(c, 1000);
        assertEq(i, 0);
    }

    /// @custom:requirement R-SBY-4 R-FEE-2
    function test_RevertWhen_FeeAbove100Percent() public {
        vm.expectRevert(abi.encodeWithSelector(RewardMath.InvalidBps.selector, uint16(10_001)));
        h.splitCurator(1, 10_001);
    }

    /// @custom:requirement R-SBY-4 R-FEE-2
    /// @custom:invariant INV-8
    function testFuzz_SplitCurator_ConservesAndRoundsTowardDepositors(uint128 amount, uint16 feeBps)
        public
        pure
    {
        feeBps = uint16(bound(feeBps, 0, 10_000));
        (uint256 c, uint256 i) = RewardMath.splitCurator(amount, feeBps);
        assertEq(c + i, amount, "no value created or lost");
        assertEq(c, FullMath.mulDiv(amount, feeBps, 10_000), "floor");
        assertLe(
            c * 10_000, uint256(amount) * feeBps, "curator never gets more than the exact share"
        );
    }
}
