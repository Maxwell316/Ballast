// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Position as PoolPosition} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookFixture} from "../../utils/HookFixture.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {BallastStandby} from "../../../src/BallastStandby.sol";
import {IBallastErrors} from "../../../src/interfaces/IBallastErrors.sol";
import {Config, Range, VaultView} from "../../../src/types/Types.sol";

/// @notice Edge cases of the vault operations and the lens: empty position slots, a zero exit notice, collateral as
/// currency1, invalid receivers and tickets, previews of out-of-range and unseeded vaults.
/// @custom:requirement R-VLT-5 R-VLT-8 R-VLT-9 R-VLT-10 R-FEE-1 R-FEE-3 R-SBY-1 R-VIEW-1 R-VIEW-2
contract EdgeCasesTest is HookFixture {
    using StateLibrary for IPoolManager;

    function _r(int24 lo, int24 hi) internal pure returns (Range memory) {
        return Range(lo, hi);
    }

    function _two(Range memory a, Range memory b) internal pure returns (Range[] memory r) {
        r = new Range[](2);
        r[0] = a;
        r[1] = b;
    }

    function _l2(uint128 a, uint128 b) internal pure returns (uint128[] memory l) {
        l = new uint128[](2);
        l[0] = a;
        l[1] = b;
    }

    function _poolLiq(uint256 v, uint256 slot, int24 lo, int24 hi) internal view returns (uint128) {
        bytes32 k =
            PoolPosition.calculatePositionKey(address(vaults), lo, hi, bytes32((v << 8) | slot));
        return IPoolManager(address(pm)).getPositionLiquidity(pid, k);
    }

    // ─── tickets and receivers ───

    function test_RevertWhen_Claim_UnknownTicketOrZeroReceiver_OrFeesToZero() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
        uint256 v = _provide(-6000, 6000, 1e19);
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.UnknownTicket.selector, 77));
        vaults.claimRedeem(77, address(this));
        uint256 t = vaults.requestRedeem(v, 1e15);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.expectRevert(IBallastErrors.InvalidReceiver.selector);
        vaults.claimRedeem(t, address(0));
        vm.expectRevert(IBallastErrors.InvalidReceiver.selector);
        vaults.claimCuratorFees(v, address(0));
    }

    // ─── empty position slots are never poked ───

    /// @notice A vault seeded with one empty slot keeps it empty through deposit, trading-fee crystallization, redeem
    /// and re-range; v4 would revert on a modification of a zero-liquidity position, so skipping is part of correctness.
    function test_EmptyPositionSlot_IsSkippedEverywhere() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
        uint256 v = vaults.createVault(_two(_r(-6000, 6000), _r(-1200, 1200)), 0, 0);
        vaults.seed(v, _l2(1e19, 0), type(uint128).max, type(uint128).max, address(this));
        assertEq(_poolLiq(v, 1, -1200, 1200), 0);

        vm.warp(vm.getBlockTimestamp() + 100);
        _swap(true, 1e16);
        vaults.deposit(v, 1e17, type(uint128).max, type(uint128).max, address(this)); // crystallizes slot 0 only
        vaults.checkpoint(v);
        uint256 t = vaults.requestRedeem(v, 1e17);
        vm.warp(vm.getBlockTimestamp() + 600);
        vaults.claimRedeem(t, address(this));
        assertEq(_poolLiq(v, 1, -1200, 1200), 0, "the empty slot stayed empty");

        // Re-range with an empty entry in the new list: the largest is slot 1, the empty slot 0 is skipped.
        vaults.rerange(v, _two(_r(-6000, 6000), _r(-1200, 1200)), _l2(0, 2e18));
        assertEq(_poolLiq(v, 0, -6000, 6000), 0);
        assertEq(_poolLiq(v, 1, -1200, 1200), 2e18);
        // And back: the now-empty first slot of the old list is skipped when removing.
        vaults.rerange(v, _two(_r(-6000, 6000), _r(-1200, 1200)), _l2(5e18, 0));
        assertEq(_poolLiq(v, 1, -1200, 1200), 0);
        assertGt(_poolLiq(v, 0, -6000, 6000), 0);
    }

    // ─── zero exit notice ───

    function test_ZeroExitNotice_TicketMaturesImmediately() public {
        Config memory c = ConfigFixture.compressed();
        c.exitNotice = 0;
        _setUpDefault(true, c, 0);
        uint256 v = _provide(-6000, 6000, 1e19);
        uint256 t = vaults.requestRedeem(v, 1e16);
        vaults.claimRedeem(t, address(this)); // same block
        assertEq(lens.ticket(t).owner, address(0));
        // Bucket width is one second for a zero notice: netting still counts a fresh ticket.
        uint256 t2 = vaults.requestRedeem(v, 1e16);
        assertEq(lens.exitingShares(v, 0), 1e16);
        vaults.cancelRedeem(t2);
        assertEq(lens.exitingShares(v, 0), 0);
    }

    // ─── collateral as currency1: the reward lands in currency0 idle ───

    function test_CollateralIsCurrency1_RewardIsCreditedToIdle0() public {
        _setUpDefault(false, ConfigFixture.compressed(), 0);
        Range[] memory r = new Range[](1);
        r[0] = _r(-6000, 6000);
        uint256 v = vaults.createVault(r, 1e17, 1000);
        uint128[] memory l = new uint128[](1);
        l[0] = 1e19;
        vaults.seed(v, l, type(uint128).max, type(uint128).max, address(this));
        BallastStandby sb = BallastStandby(address(vaults.standby()));
        quote.mint(ConfigFixture.SPONSOR, 1e18);
        vm.startPrank(ConfigFixture.SPONSOR);
        quote.approve(address(sb), type(uint256).max);
        sb.fundStandby(1e15);
        sb.setStandbyRate(1e9);
        vm.stopPrank();
        vaults.checkpoint(v);
        vm.warp(vm.getBlockTimestamp() + 100);
        VaultView memory before_ = lens.vault(v);
        vaults.checkpoint(v);
        VaultView memory after_ = lens.vault(v);
        assertGt(after_.idle0, before_.idle0, "quote is currency0 here");
        assertGt(after_.curatorOwed0, before_.curatorOwed0);
        assertEq(after_.idle1, before_.idle1, "the collateral side is untouched by rewards");
    }

    // ─── lens previews (unseeded, min with commitment and depth vectors: test/unit/lens/LensDepth.t.sol) ───

    function test_PreviewRedeem_MatchesExecution() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
        uint256 v = _provide(-6000, 6000, 1e19);
        (uint128 p0, uint128 p1) = lens.previewRedeem(v, 2e17);
        uint256 t = vaults.requestRedeem(v, 2e17);
        vm.warp(vm.getBlockTimestamp() + 600);
        (uint128 a0, uint128 a1) = vaults.claimRedeem(t, address(this));
        assertApproxEqAbs(p0, a0, 2);
        assertApproxEqAbs(p1, a1, 2);
    }

    /// @notice Positions entirely above or below spot hold a single token; previews price each correctly.
    function test_Previews_OutOfRangePositions() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
        uint256 above = vaults.createVault(_one(600, 6000), 0, 0);
        uint256 below = vaults.createVault(_one(-6000, -600), 0, 0);
        uint128[] memory l = new uint128[](1);
        l[0] = 1e19;
        vaults.seed(above, l, type(uint128).max, type(uint128).max, address(this));
        vaults.seed(below, l, type(uint128).max, type(uint128).max, address(this));
        (uint128 a0, uint128 a1) = lens.previewDeposit(above, 1e17);
        assertGt(a0, 0, "range above spot holds only collateral (currency0)");
        assertEq(a1, 0);
        (a0, a1) = lens.previewDeposit(below, 1e17);
        assertEq(a0, 0);
        assertGt(a1, 0, "range below spot holds only quote (currency1)");
    }

    function _one(int24 lo, int24 hi) internal pure returns (Range[] memory r) {
        r = new Range[](1);
        r[0] = Range(lo, hi);
    }
}
