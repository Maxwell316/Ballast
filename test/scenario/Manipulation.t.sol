// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StressDriver} from "../utils/StressDriver.sol";
import {Matrix, C0Before, C1After} from "../utils/Matrix.sol";
import {ConfigFixture} from "../utils/ConfigFixture.sol";
import {BallastStandby} from "../../src/BallastStandby.sol";
import {IBallastErrors} from "../../src/interfaces/IBallastErrors.sol";
import {LockState, Range} from "../../src/types/Types.sol";

/// @notice The manipulation scenarios of THREAT_MODEL (T3, T6, T4, T5): what an attacker can do to the stress gate and
/// to the standby, what it costs, and what the mitigation leaves. Every cost is measured with real swaps and reported
/// through `-vv` logs; the assertions are bounds, not prints.
/// @dev Fixture: vault 1 over [-12000, 12000], liquidity 1e19 (collateral depth about 4e17 in the 750 bps band); compressed
/// windows (anchor 1 h, short 5 min, interval 60 s, calm 10 min, notice 10 min); swap fee 0.3%. The attacker is a
/// separate funded account so its balance change is its cost. Run for both collateral orderings.
/// @custom:requirement R-STR-4 R-STR-7 R-SBY-3
abstract contract ManipulationBase is StressDriver, Matrix {
    address internal constant ATT = address(0xA77AC);
    address internal constant SNIPER = address(0x5A1FE5);
    uint128 internal constant RATE = 1e12;
    uint256 internal matured;

    function _setUpManip(uint32 maxStressLock) internal {
        lensAfterInit = _lensAfter();
        _setUpStressSide(maxStressLock, _c0());
        for (uint256 i; i < 2; ++i) {
            address who = i == 0 ? ATT : SNIPER;
            collateral.mint(who, 1e27);
            quote.mint(who, 1e27);
            vm.startPrank(who);
            collateral.approve(address(swapRouter), type(uint256).max);
            quote.approve(address(swapRouter), type(uint256).max);
            collateral.approve(address(vaults), type(uint256).max);
            quote.approve(address(vaults), type(uint256).max);
            vm.stopPrank();
        }
        matured = vaults.requestRedeem(1, 1e17); // matures during the warm-up, before any manipulation
        _warmUp();
    }

    function _swapAs(address who, bool sellCollateral, uint256 amountIn) internal {
        vm.prank(who);
        _swap(sellCollateral, amountIn);
    }

    function _expectLocked() internal {
        vm.expectPartialRevert(IBallastErrors.StressLockActive.selector);
    }

    function _fundStandby() internal returns (BallastStandby sb) {
        sb = BallastStandby(address(vaults.standby()));
        quote.mint(ConfigFixture.SPONSOR, 1e24);
        vm.startPrank(ConfigFixture.SPONSOR);
        quote.approve(address(sb), type(uint256).max);
        sb.fundStandby(1e21);
        sb.setStandbyRate(RATE);
        vm.stopPrank();
    }

    // ─── T3: push the price to trigger stress and trap LPs ───

    /// @notice A spike inside one block (the attacker's cheapest tool) cannot enter stress: the accumulator weights each
    /// tick by the time spent at it, so a price that is back where it started within the same timestamp leaves the
    /// short TWAP unmoved. It costs the attacker the fee on both legs.
    function test_T3_InBlockSpike_NeverEntersStress_AndCostsAtLeastBothFees() public {
        _setUpManip(1 hours);
        uint256 c0 = collateral.balanceOf(ATT);
        uint256 q0 = quote.balanceOf(ATT);
        _swapAs(ATT, true, CRASH);
        int24 pushed = _tick();
        assertGt(
            int256(pushed) * int256(_liquidationSign()), 500, "the spike moved the price about 6%"
        );
        _swapAs(ATT, false, quote.balanceOf(ATT) - q0); // back, same timestamp
        for (uint256 i; i < 6; ++i) {
            _step(60);
            assertEq(uint8(_stored()), uint8(LockState.CALM), "the spike left no trace in the TWAP");
        }
        uint256 lost = c0 - collateral.balanceOf(ATT);
        emit log_named_uint("T3 in-block spike: notional (collateral raw)", CRASH);
        emit log_named_uint("T3 in-block spike: cost (collateral raw)", lost);
        emit log_named_uint("T3 in-block spike: cost / notional (ppm)", lost * 1e6 / CRASH);
        // Each leg pays the 0.3% fee on its input: about 2 x 3,000 ppm of the notional, and nothing else, because the price
        // impact is reversed. Slightly under 2 fees (here 98.3% of them): the buy leg's net input is the quote received less
        // its fee, so the price stops a little short of where it started and the attacker recovers a little more collateral
        // than a symmetric round trip would give. The bounds are 95% and 100% of 2 fees.
        assertGe(lost, CRASH * 2 * cfg.fee / 1e6 * 95 / 100, "close to both fees");
        assertLe(lost, CRASH * 2 * cfg.fee / 1e6, "and no more than both fees");
    }

    /// @notice A sustained push does enter stress (that is the design: a real crash looks the same). The trap is bounded:
    /// exits are refused only until `maxStressLock`, the attacker re-pushing after expiry cannot re-arm the lock, and
    /// holding the price costs the capital plus both fees when the position is unwound. The cost of the trap is reported.
    function test_T3_SustainedPush_TrapsExitsOnlyUntilMaxStressLock_AndCannotRearm() public {
        _setUpManip(1 hours);
        uint256 c0 = collateral.balanceOf(ATT);
        uint256 q0 = quote.balanceOf(ATT);
        _swapAs(ATT, true, CRASH);
        uint256 steps = _stepUntil(LockState.STRESS, 20);
        assertEq(uint8(_stored()), uint8(LockState.STRESS), "a sustained push enters stress");
        emit log_named_uint(
            "T3 sustained push: seconds of holding before the lock engaged", steps * 60
        );
        assertLe(steps * 60, 600, "the lock engages within the notice period");

        _expectLocked();
        vaults.claimRedeem(matured, address(this)); // trapped

        // After maxStressLock the same exit goes through although the attacker still holds the price down.
        vm.warp(hook.stressStorage().stressStartedAt + 1 hours + 1);
        vaults.claimRedeem(matured, address(this));
        assertEq(lens.ticket(matured).owner, address(0), "released at maxStressLock");

        // The attacker pushes again; the state never returned to CALM, so the lock cannot re-arm (D-6).
        uint256 t2 = vaults.requestRedeem(1, 1e16);
        vm.warp(vm.getBlockTimestamp() + 601);
        _swapAs(ATT, true, 1e17);
        vaults.claimRedeem(t2, address(this));
        assertEq(lens.ticket(t2).owner, address(0), "no second trap without an intervening CALM");

        // Unwind and measure the cost of the whole operation.
        _swapAs(ATT, false, quote.balanceOf(ATT) - q0);
        uint256 notional = CRASH + 1e17;
        uint256 lost = c0 - collateral.balanceOf(ATT);
        emit log_named_uint("T3 sustained push: notional (collateral raw)", notional);
        emit log_named_uint("T3 sustained push: cost incl. unwind (collateral raw)", lost);
        emit log_named_uint("T3 sustained push: cost / notional (ppm)", lost * 1e6 / notional);
        emit log_named_uint(
            "T3 sustained push: notional / vault depth in the band (ppm)",
            notional * 1e6 / lens.vaultDepth(1)
        );
        // A lower bound on the cost: both fees on the legs (the price impact reverses). Capital lockup and the risk that
        // arbitrageurs restore the price are on top and are not measurable on chain.
        assertGe(lost, notional * 2 * cfg.fee / 1e6 * 95 / 100);
    }

    // ─── T6: reward sniping by timing a deposit ───

    /// @notice A depositor who arrives just after a long accrual gains only the share of the rewards earned while holding:
    /// the deposit checkpoints first, so it pays for the idle that already holds the rewards credited before it.
    function test_T6_RewardSniping_GainsOnlyTheShareOfRewardsEarnedWhileHolding() public {
        _setUpManip(1 hours);
        BallastStandby sb = _fundStandby();
        vaults.setCommitment(1, 3e17); // below the 3.97e17 depth, so the commitment is the eligible depth
        vaults.checkpoint(1);
        vm.warp(vm.getBlockTimestamp() + 300); // a full accrual interval of rewards sits uncredited
        uint256 supplyBefore = vaults.shareToken().totalSupply(1);
        uint128 s = 1e18; // as many shares as exist: the sniper would own half the vault

        uint256 qA = quote.balanceOf(SNIPER);
        uint256 cA = collateral.balanceOf(SNIPER);
        vm.prank(SNIPER);
        vaults.deposit(1, s, type(uint128).max, type(uint128).max, SNIPER);
        uint256 qB = quote.balanceOf(SNIPER);
        uint256 creditedAtDeposit = sb.standbyInfo().totalCredited;
        assertGt(
            creditedAtDeposit, 0, "the interval before the deposit was credited at the deposit"
        );

        vm.prank(SNIPER);
        uint256 id = vaults.requestRedeem(1, s);
        vm.warp(vm.getBlockTimestamp() + 300);
        vaults.checkpoint(1);
        vm.warp(vm.getBlockTimestamp() + 301);
        vm.prank(SNIPER);
        vaults.claimRedeem(id, SNIPER);
        uint256 earnedWhileHolding = sb.standbyInfo().totalCredited - creditedAtDeposit;
        uint256 fair = FullMath.mulDiv(earnedWhileHolding, s, supplyBefore + s);
        uint256 snipeTarget = FullMath.mulDiv(creditedAtDeposit, s, supplyBefore + s);

        uint256 returned = quote.balanceOf(SNIPER) - qB; // what the exit returned
        uint256 paid = qA - qB; // what the deposit cost
        emit log_named_uint("T6 rewards credited before the deposit (quote raw)", creditedAtDeposit);
        emit log_named_uint("T6 rewards credited while the sniper held shares", earnedWhileHolding);
        emit log_named_uint(
            "T6 share of the earlier rewards (what sniping would have taken)", snipeTarget
        );
        emit log_named_uint("T6 sniper net quote gain", returned > paid ? returned - paid : 0);
        emit log_named_uint("T6 fair share of the rewards earned while holding", fair);
        // The net gain never exceeds the fair share earned while holding (+2 wei of rounding); the share of the earlier
        // rewards that sniping would have taken is not in it.
        assertLe(returned, paid + fair + 2, "no gain beyond the rewards earned while holding");
        assertLe(
            collateral.balanceOf(SNIPER),
            cA,
            "no collateral gain: rounding never favours the depositor"
        );
        assertGt(snipeTarget, 2, "the test is not vacuous: there was something to snipe");
    }

    // ─── T5: standby farming with depth that is only there around a checkpoint ───

    /// @notice A curator who re-ranges into a much deeper layout does not get the deeper reward for the interval that the
    /// re-range closes: accrual at a re-range uses `min(depth before, depth after)` (and the start sample), so the interval
    /// pays what was really there throughout. Deep depth pays from the next interval on, once it has been present at both
    /// ends, up to the commitment. A deposit cannot be used for the same trick in reverse (flash in, flash out): leaving
    /// takes the exit notice, which is longer than an accrual interval (`TicketNotMature`, asserted in
    /// `test_Redeem_EscrowsSharesThenPaysAtMaturity_ToAChosenReceiver`). The numbers are relative to a measured baseline so that a tick or two of drift does not matter.
    function test_T5_FlashDepthEarnsNothingForTheIntervalThatClosesTheRerange() public {
        _setUpManip(1 hours);
        BallastStandby sb = _fundStandby();
        Range[] memory thin = new Range[](1);
        thin[0] = Range(-6000, 6000);
        uint256 v2 = vaults.createVault(thin, 1e17, 0); // commitment above the thin depth (4e16), below the deep one
        uint128[] memory l = new uint128[](1);
        l[0] = 1e18;
        vaults.seed(v2, l, type(uint128).max, type(uint128).max, address(this));
        vaults.checkpoint(v2); // the clock starts here, with the thin sample

        // Baseline: one interval of thin depth.
        uint256 c0 = sb.standbyInfo().totalCredited;
        vm.warp(vm.getBlockTimestamp() + 100);
        vaults.checkpoint(v2);
        uint256 baseline = sb.standbyInfo().totalCredited - c0;
        assertGt(baseline, 0);

        // The curator re-ranges into three times the depth for the same capital, at the end of the next interval.
        Range[] memory deep = new Range[](1);
        deep[0] = Range(-1200, 1200);
        l[0] = 3e18;
        uint256 c1 = sb.standbyInfo().totalCredited;
        vm.warp(vm.getBlockTimestamp() + 100);
        vaults.rerange(v2, deep, l);
        uint256 closing = sb.standbyInfo().totalCredited - c1;
        assertGt(
            lens.vaultDepth(v2),
            2e17 / 2,
            "the new layout really is deeper and covers the commitment"
        );

        // The next interval, with the deep layout present at both ends, pays up to the commitment.
        uint256 c2 = sb.standbyInfo().totalCredited;
        vm.warp(vm.getBlockTimestamp() + 100);
        vaults.checkpoint(v2);
        uint256 held = sb.standbyInfo().totalCredited - c2;

        emit log_named_uint("T5 interval of thin depth (baseline)", baseline);
        emit log_named_uint("T5 interval closed by the re-range into 3x depth", closing);
        emit log_named_uint(
            "T5 next interval, deep at both ends (capped by the commitment 1e17)", held
        );
        assertApproxEqRel(
            closing, baseline, 1e16, "the interval closing the re-range pays what was there: thin"
        );
        assertEq(
            held,
            uint256(1e17) * 100 * RATE / 1e18,
            "deep at both ends pays the commitment: 1e17 x 100 s x rate"
        );
        assertGt(held, closing * 2, "the held interval earned more than twice the closing one");
    }

    // ─── T4: push the price the other way to suppress stress ───

    /// @notice An attacker who buys back every sale as it happens keeps the machine in CALM for as long as it does so; the
    /// same sell flow without it engages stress within the same number of minutes. The price of suppression is that the
    /// attacker absorbs the whole sell flow: the collateral it holds is reported (its loss is the distance the market
    /// would otherwise have fallen, plus the fees). This is the residual risk of T4, bounded by the attacker's capital,
    /// not removed.
    function test_T4_Suppression_HoldsCalmOnlyWhileTheAttackerAbsorbsTheSellFlow() public {
        _setUpManip(1 hours);
        uint256 snap = vm.snapshotState();

        // Control: a real sell flow, one sale a minute, no attacker.
        for (uint256 i; i < 12; ++i) {
            _step(60);
            _swap(true, CRASH);
        }
        assertEq(uint8(_stored()), uint8(LockState.STRESS), "control: the sell flow engages stress");
        assertTrue(vm.revertToState(snap));

        // Attack: after each sale the attacker buys back what the seller received.
        uint256 attC = collateral.balanceOf(ATT);
        uint256 attQ = quote.balanceOf(ATT);
        for (uint256 i; i < 12; ++i) {
            _step(60);
            uint256 qBefore = quote.balanceOf(address(this));
            _swap(true, CRASH);
            _swapAs(ATT, false, quote.balanceOf(address(this)) - qBefore);
            assertEq(uint8(_stored()), uint8(LockState.CALM), "suppressed: still CALM");
        }
        uint256 absorbed = collateral.balanceOf(ATT) - attC;
        uint256 spent = attQ - quote.balanceOf(ATT);
        emit log_named_uint("T4 sell flow offered (collateral raw)", 12 * CRASH);
        emit log_named_uint("T4 collateral the attacker absorbed", absorbed);
        emit log_named_uint("T4 quote the attacker spent", spent);
        assertGe(
            absorbed, 12 * CRASH * 98 / 100, "suppression means holding the whole flow (less fees)"
        );
    }
}

contract ManipulationTest_C0Before is ManipulationBase, C0Before {}

contract ManipulationTest_C1After is ManipulationBase, C1After {}
