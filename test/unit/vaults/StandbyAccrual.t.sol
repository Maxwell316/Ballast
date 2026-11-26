// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HookFixture} from "../../utils/HookFixture.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {BallastStandby} from "../../../src/BallastStandby.sol";
import {IBallastErrors} from "../../../src/interfaces/IBallastErrors.sol";
import {IBallastEvents} from "../../../src/interfaces/IBallastEvents.sol";
import {RewardMath} from "../../../src/libraries/RewardMath.sol";
import {CuratorRecord, Range, StandbyInfo, VaultView} from "../../../src/types/Types.sol";

/// @notice The sponsor-funded standby: funding, the rate, accrual on verified depth, the curator cut, the fund cap and
/// depletion, breach pausing, reward sniping and the drought (M6; R-SBY-1..7, R-FEE-2, G-5, INV-8).
/// @custom:requirement R-SBY-1 R-SBY-2 R-SBY-3 R-SBY-4 R-SBY-5 R-SBY-6 R-FEE-2
/// @custom:guarantee G-5
contract StandbyAccrualTest is HookFixture {
    uint128 internal constant RATE = 1e12; // the configured maximum: 1e-6 quote raw per collateral raw per second
    uint128 internal constant COMMITMENT = 3e17;
    address internal constant BOB = address(0xB0B0);

    BallastStandby internal standby;
    uint256 internal v;

    function setUp() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
        standby = BallastStandby(address(vaults.standby()));
        Range[] memory r = new Range[](1);
        r[0] = Range(-6000, 6000);
        v = vaults.createVault(r, COMMITMENT, 1000); // 10% curator cut
        uint128[] memory l = new uint128[](1);
        l[0] = 1e19;
        vaults.seed(v, l, type(uint128).max, type(uint128).max, address(this));
        quote.mint(ConfigFixture.SPONSOR, 1e24);
        vm.prank(ConfigFixture.SPONSOR);
        quote.approve(address(standby), type(uint256).max);
        collateral.mint(BOB, 1e27);
        quote.mint(BOB, 1e27);
        vm.startPrank(BOB);
        collateral.approve(address(vaults), type(uint256).max);
        quote.approve(address(vaults), type(uint256).max);
        vm.stopPrank();
    }

    function _fund(uint128 amount) internal {
        vm.prank(ConfigFixture.SPONSOR);
        standby.fundStandby(amount);
    }

    function _rate(uint128 rate) internal {
        vm.prank(ConfigFixture.SPONSOR);
        standby.setStandbyRate(rate);
    }

    function _quoteIdle() internal view returns (uint256) {
        return lens.vault(v).idle1; // collateral is currency0 in this fixture, so quote is currency1
    }

    function _quoteOwed() internal view returns (uint256) {
        return lens.vault(v).curatorOwed1;
    }

    // ─── funding and rate ───

    function test_Fund_PullsQuoteAndHoldsItAsPoolManagerClaims() public {
        uint256 s0 = quote.balanceOf(ConfigFixture.SPONSOR);
        vm.expectEmit(true, false, false, true);
        emit IBallastEvents.StandbyFunded(ConfigFixture.SPONSOR, 5e15);
        _fund(5e15);
        assertEq(s0 - quote.balanceOf(ConfigFixture.SPONSOR), 5e15);
        assertEq(standby.standbyInfo().fundBalance, 5e15);
        assertEq(pm.balanceOf(address(standby), uint256(uint160(address(quote)))), 5e15);
    }

    function test_RevertWhen_FundOrRate_NotSponsorOrOutOfBounds() public {
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.NotSponsor.selector, address(this)));
        standby.fundStandby(1);
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.NotSponsor.selector, address(this)));
        standby.setStandbyRate(1);
        vm.prank(ConfigFixture.SPONSOR);
        vm.expectRevert(IBallastErrors.StandbyRateTooHigh.selector);
        standby.setStandbyRate(RATE + 1);
        vm.prank(ConfigFixture.SPONSOR);
        vm.expectRevert(IBallastErrors.ZeroShares.selector);
        standby.fundStandby(0);
    }

    function test_RevertWhen_AccrueCalledByAnyoneButTheVaults() public {
        vm.expectRevert(abi.encodeWithSelector(BallastStandby.NotVaultsContract.selector, address(this)));
        standby.accrue(1e18, 100);
    }

    // ─── accrual ───

    /// @notice reward = floor(min(depth samples, commitment) x rate x dt / 1e18), split by the curator fee.
    function test_Accrual_PaysOnVerifiedDepth_CappedByCommitment_WithCuratorCut() public {
        _fund(1e15);
        _rate(RATE);
        vaults.checkpoint(v); // start the clock with the rate set
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 100);
        uint256 idleBefore = _quoteIdle();
        uint256 owedBefore = _quoteOwed();
        vaults.checkpoint(v);
        // The depth (about 3.97e17) exceeds the commitment, so the commitment is the eligible depth.
        uint256 expected = RewardMath.accrue(COMMITMENT, RATE, 100);
        assertEq(expected, 3e13);
        assertEq(_quoteOwed() - owedBefore, expected / 10, "10% to the curator");
        assertEq(_quoteIdle() - idleBefore, expected - expected / 10, "the rest to holders' idle");
        StandbyInfo memory info = standby.standbyInfo();
        assertEq(info.totalCredited, expected);
        assertEq(info.fundBalance, 1e15 - expected);
        // INV-3: the vaults' quote claims cover the new balances.
        assertGe(pm.balanceOf(address(vaults), uint256(uint160(address(quote)))), _quoteIdle() + _quoteOwed());
        CuratorRecord memory rec = lens.vaultRecord(v);
        assertEq(rec.depthSeconds, uint256(COMMITMENT) * 100 + 0, "depth-seconds of the eligible depth (first interval had none)");
    }

    function test_Accrual_IntervalIsCappedAtMaxAccrualInterval() public {
        _fund(1e15);
        _rate(RATE);
        vaults.checkpoint(v);
        vm.warp(vm.getBlockTimestamp() + 10_000); // far above the 300 s cap
        uint256 owed = _quoteOwed();
        uint256 idle = _quoteIdle();
        vaults.checkpoint(v);
        uint256 got = (_quoteOwed() - owed) + (_quoteIdle() - idle);
        assertEq(got, RewardMath.accrue(COMMITMENT, RATE, 300), "only 300 s are paid, not 10,000");
    }

    function test_Accrual_ZeroWhenRateIsZero_TheDrought() public {
        _fund(1e15);
        vaults.checkpoint(v);
        vm.warp(vm.getBlockTimestamp() + 200);
        uint256 idle = _quoteIdle();
        vaults.checkpoint(v);
        assertEq(_quoteIdle(), idle, "no rate, no reward");
        assertEq(standby.standbyInfo().totalCredited, 0);
        // Depth views are untouched by the drought; only time-based exits would change them.
        assertGt(lens.liveDepth(750, 0), 0);
    }

    function test_Accrual_StopsWhenTheFundRunsOut_AndEmitsDepletedOnce() public {
        _fund(1e13); // less than one 100 s interval pays (3e13)
        _rate(RATE);
        vaults.checkpoint(v);
        vm.warp(vm.getBlockTimestamp() + 100);
        vm.recordLogs();
        vaults.checkpoint(v);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, keccak256("StandbyDepleted()")), 1, "depleted once");
        assertEq(standby.standbyInfo().fundBalance, 0);
        assertEq(standby.standbyInfo().totalCredited, 1e13, "capped by the fund");
        vm.warp(vm.getBlockTimestamp() + 100);
        vm.recordLogs();
        vaults.checkpoint(v);
        assertEq(_count(vm.getRecordedLogs(), keccak256("StandbyDepleted()")), 0, "not again");
        assertEq(standby.standbyInfo().totalCredited, 1e13);
    }

    function _count(Vm.Log[] memory logs, bytes32 sig) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) ++n;
        }
    }

    // ─── breach pauses accrual ───

    function test_Accrual_PausesWhileTheVaultIsInBreach_AndResumesWhenCovered() public {
        _fund(1e15);
        _rate(RATE);
        vaults.checkpoint(v);
        vaults.setCommitment(v, 5e17); // above the depth the vault commits (about 3.97e17)
        vm.warp(vm.getBlockTimestamp() + 10);
        vaults.checkpoint(v); // grace clock starts
        vm.warp(vm.getBlockTimestamp() + 300);
        vaults.checkpoint(v); // flagged
        assertGt(lens.vault(v).breachSince, 0);
        uint256 credited = standby.standbyInfo().totalCredited;
        vm.warp(vm.getBlockTimestamp() + 200);
        vaults.checkpoint(v);
        assertEq(standby.standbyInfo().totalCredited, credited, "no reward while in breach (G-5)");

        // Restore coverage by lowering the commitment (after the notice), then accrual resumes.
        vaults.setCommitment(v, COMMITMENT);
        vm.warp(vm.getBlockTimestamp() + 600);
        vaults.checkpoint(v); // applies the decrease and clears the breach; this interval was still in breach
        assertEq(lens.vault(v).breachSince, 0);
        credited = standby.standbyInfo().totalCredited;
        vm.warp(vm.getBlockTimestamp() + 100);
        vaults.checkpoint(v);
        assertGt(standby.standbyInfo().totalCredited, credited, "accrual resumed");
    }

    // ─── sniping (T6) ───

    /// @notice A depositor who enters just before a checkpoint cannot capture the reward earned before him: his
    /// deposit checkpoints first, so the idle he pays a proportional share of already contains it.
    function test_NoRewardSniping_DepositThenImmediateExitGainsNothing() public {
        _fund(1e15);
        _rate(RATE);
        vaults.checkpoint(v);
        vm.warp(vm.getBlockTimestamp() + 250); // 250 s of unclaimed reward, not yet credited
        (uint256 c0, uint256 q0) = (collateral.balanceOf(BOB), quote.balanceOf(BOB));
        vm.prank(BOB);
        vaults.deposit(v, 5e17, type(uint128).max, type(uint128).max, BOB);
        // The sponsor stops the stream so the holding period itself earns nothing: any gain left would be a snipe of
        // the reward earned before BOB entered. (Rewards earned while holding are legitimately his share.)
        _rate(0);
        vm.prank(BOB);
        uint256 t = vaults.requestRedeem(v, 5e17);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.prank(BOB);
        vaults.claimRedeem(t, BOB);
        (uint256 c1, uint256 q1) = (collateral.balanceOf(BOB), quote.balanceOf(BOB));
        assertLe(c1, c0, "no collateral gain");
        assertLe(q1, q0, "no quote gain: the reward credited at his deposit was paid for, in kind");
    }

    // ─── re-range cannot game the sample ───

    function test_Rerange_AccruesOnTheMinimumOfBeforeAndAfter() public {
        _fund(1e15);
        _rate(RATE);
        vaults.checkpoint(v);
        vm.warp(vm.getBlockTimestamp() + 100);
        // Re-range into a position whose depth is far below the commitment but still covers it: depth after = 3e17.
        Range[] memory r = new Range[](1);
        r[0] = Range(-1200, 1200);
        uint128[] memory l = new uint128[](1);
        l[0] = 7.6e18; // depth about 3.02e17, just above the commitment
        uint256 credited = standby.standbyInfo().totalCredited;
        vaults.rerange(v, r, l);
        uint256 paid = standby.standbyInfo().totalCredited - credited;
        // eligible = min(start sample, now sample, before sample, commitment): the interval is paid on the smaller of
        // the two depths, never on the larger.
        assertLe(paid, RewardMath.accrue(COMMITMENT, RATE, 100));
        assertGt(paid, 0);
    }
}
