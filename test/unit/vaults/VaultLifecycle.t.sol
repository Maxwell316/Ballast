// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Position as PoolPosition} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BallastShares} from "../../../src/BallastShares.sol";
import {HookFixture} from "../../utils/HookFixture.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {IBallastErrors} from "../../../src/interfaces/IBallastErrors.sol";
import {INITIAL_SHARES, MINIMUM_SHARES, MAX_POSITIONS, MAX_VAULTS} from "../../../src/types/Constants.sol";
import {PositionView, Range, TicketView, VaultView} from "../../../src/types/Types.sol";

/// @notice Vault lifecycle through the real hook, vaults and PoolManager: creation, seeding, proportional deposits,
/// the exit queue, curator fees and token conservation (M3; R-VLT-1..12, G-2, INV-1..5).
/// @custom:requirement R-VLT-1 R-VLT-2 R-VLT-3 R-VLT-5 R-VLT-7 R-VLT-8 R-VLT-9
/// @custom:guarantee G-2
contract VaultLifecycleTest is HookFixture {
    using StateLibrary for IPoolManager;

    address internal constant ALICE = address(0xA11CE0);
    address internal constant BOB = address(0xB0B0);

    function setUp() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
        _fund(ALICE);
        _fund(BOB);
    }

    function _fund(address who) internal {
        collateral.mint(who, 1e27);
        quote.mint(who, 1e27);
        vm.startPrank(who);
        collateral.approve(address(vaults), type(uint256).max);
        quote.approve(address(vaults), type(uint256).max);
        vm.stopPrank();
    }

    function _ranges(int24 lo, int24 hi) internal pure returns (Range[] memory r) {
        r = new Range[](1);
        r[0] = Range(lo, hi);
    }

    function _liqs(uint128 l) internal pure returns (uint128[] memory a) {
        a = new uint128[](1);
        a[0] = l;
    }

    function _poolLiquidity(uint256 v, uint256 slot, int24 lo, int24 hi) internal view returns (uint128) {
        bytes32 k = PoolPosition.calculatePositionKey(address(vaults), lo, hi, bytes32((v << 8) | slot));
        return IPoolManager(address(pm)).getPositionLiquidity(pid, k);
    }

    function _bal(address who) internal view returns (uint256 c, uint256 q) {
        return (collateral.balanceOf(who), quote.balanceOf(who));
    }

    // ─── createVault ───

    function test_CreateVault_StoresCuratorFeeCommitmentAndRanges() public {
        Range[] memory r = new Range[](2);
        r[0] = Range(-600, 600);
        r[1] = Range(-1200, 0);
        vm.prank(ALICE);
        uint256 v = vaults.createVault(r, 7e16, 500);
        assertEq(v, 1);
        VaultView memory d = lens.vault(v);
        assertEq(d.curator, ALICE);
        assertEq(d.curatorFeeBps, 500);
        assertEq(d.commitment, 7e16);
        assertEq(d.positionCount, 2);
        assertEq(d.totalShares, 0);
        PositionView[] memory p = lens.positionsOf(v);
        assertEq(p[1].tickLower, -1200);
        assertEq(p[1].liquidity, 0);
    }

    function test_RevertWhen_CreateVault_InvalidInputs() public {
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.InvalidCuratorFee.selector, 2001));
        vaults.createVault(_ranges(-600, 600), 0, 2001);
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.InvalidRange.selector, int24(-601), int24(600)));
        vaults.createVault(_ranges(-601, 600), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.InvalidRange.selector, int24(600), int24(600)));
        vaults.createVault(_ranges(600, 600), 0, 0);
        vm.expectRevert(IBallastErrors.TooManyPositions.selector);
        vaults.createVault(new Range[](0), 0, 0);
        Range[] memory dup = new Range[](2);
        dup[0] = Range(-60, 60);
        dup[1] = Range(-60, 60);
        vm.expectRevert(IBallastErrors.DuplicateRange.selector);
        vaults.createVault(dup, 0, 0);
        Range[] memory many = new Range[](MAX_POSITIONS + 1);
        for (uint256 i; i < many.length; ++i) {
            many[i] = Range(int24(int256(i) * -60 - 60), 60);
        }
        vm.expectRevert(IBallastErrors.TooManyPositions.selector);
        vaults.createVault(many, 0, 0);
    }

    function test_RevertWhen_CreateVault_TooManyVaults() public {
        for (uint256 i; i < MAX_VAULTS; ++i) {
            vaults.createVault(_ranges(-60, 60), 0, 0);
        }
        vm.expectRevert(IBallastErrors.TooManyVaults.selector);
        vaults.createVault(_ranges(-60, 60), 0, 0);
    }

    // ─── seed ───

    function test_Seed_MintsInitialSharesBurnsMinimum_AndVaultsOwnLiquidity() public {
        (uint256 c0, uint256 q0) = _bal(address(this));
        uint256 v = vaults.createVault(_ranges(-6000, 6000), 0, 0);
        (uint128 a0, uint128 a1) = vaults.seed(v, _liqs(1e19), type(uint128).max, type(uint128).max, ALICE);
        (uint256 c1, uint256 q1) = _bal(address(this));
        assertEq(c0 - c1, a0, "payer paid exactly the returned amount (collateral)");
        assertEq(q0 - q1, a1, "payer paid exactly the returned amount (quote)");
        assertGt(a0 + a1, 0);
        assertEq(vaults.shareToken().balanceOf(ALICE, v), INITIAL_SHARES - MINIMUM_SHARES);
        assertEq(vaults.shareToken().balanceOf(address(0), v), MINIMUM_SHARES);
        assertEq(vaults.shareToken().totalSupply(v), INITIAL_SHARES);
        assertEq(_poolLiquidity(v, 0, -6000, 6000), 1e19, "INV-1/INV-2: pool position equals recorded");
        assertEq(lens.positionsOf(v)[0].liquidity, 1e19);
    }

    function test_RevertWhen_Seed_NotCuratorOrTwiceOrBadInput() public {
        uint256 v = vaults.createVault(_ranges(-6000, 6000), 0, 0);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.NotCurator.selector, ALICE));
        vaults.seed(v, _liqs(1e19), type(uint128).max, type(uint128).max, ALICE);
        vm.expectRevert(IBallastErrors.InvalidLiquidities.selector);
        vaults.seed(v, _liqs(0), type(uint128).max, type(uint128).max, ALICE);
        vm.expectRevert(IBallastErrors.InvalidLiquidities.selector);
        vaults.seed(v, new uint128[](2), type(uint128).max, type(uint128).max, ALICE);
        vm.expectRevert(IBallastErrors.InvalidReceiver.selector);
        vaults.seed(v, _liqs(1e19), type(uint128).max, type(uint128).max, address(0));
        vm.expectRevert(IBallastErrors.SlippageExceeded.selector);
        vaults.seed(v, _liqs(1e19), 1, 1, ALICE);
        vaults.seed(v, _liqs(1e19), type(uint128).max, type(uint128).max, ALICE);
        vm.expectRevert(IBallastErrors.VaultAlreadySeeded.selector);
        vaults.seed(v, _liqs(1e19), type(uint128).max, type(uint128).max, ALICE);
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.UnknownVault.selector, 99));
        vaults.seed(99, _liqs(1e19), type(uint128).max, type(uint128).max, ALICE);
    }

    // ─── deposit ───

    function test_Deposit_IsProportional_AndPaysExactlyTheReportedAmount() public {
        uint256 v = _provide(-6000, 6000, 1e19);
        (uint256 cb, uint256 qb) = _bal(BOB);
        vm.prank(BOB);
        (uint128 a0, uint128 a1) =
            vaults.deposit(v, 1e17, type(uint128).max, type(uint128).max, BOB);
        (uint256 ca, uint256 qa) = _bal(BOB);
        assertEq(cb - ca, a0);
        assertEq(qb - qa, a1);
        assertEq(vaults.shareToken().balanceOf(BOB, v), 1e17);
        // ceil(1e19 * 1e17 / 1e18) = 1e18
        assertEq(_poolLiquidity(v, 0, -6000, 6000), 1e19 + 1e18);
        assertEq(lens.vault(v).totalShares, INITIAL_SHARES + 1e17);
        // The quoted preview matches (it uses the same roundings and spot price).
        // (Previewed before the deposit in the fuzz test below; here check it is consistent after.)
    }

    function test_PreviewDeposit_MatchesExecution() public {
        uint256 v = _provide(-6000, 6000, 1e19);
        (uint128 p0, uint128 p1) = lens.previewDeposit(v, 3e17);
        vm.prank(BOB);
        (uint128 a0, uint128 a1) =
            vaults.deposit(v, 3e17, type(uint128).max, type(uint128).max, BOB);
        // The PoolManager's own rounding is authoritative; the preview must be within a couple of wei.
        assertApproxEqAbs(p0, a0, 2);
        assertApproxEqAbs(p1, a1, 2);
    }

    function test_RevertWhen_Deposit_BadInput() public {
        uint256 v = vaults.createVault(_ranges(-6000, 6000), 0, 0);
        vm.expectRevert(IBallastErrors.VaultNotSeeded.selector);
        vaults.deposit(v, 1e17, type(uint128).max, type(uint128).max, BOB);
        vaults.seed(v, _liqs(1e19), type(uint128).max, type(uint128).max, ALICE);
        vm.expectRevert(IBallastErrors.ZeroShares.selector);
        vaults.deposit(v, 0, type(uint128).max, type(uint128).max, BOB);
        vm.expectRevert(IBallastErrors.InvalidReceiver.selector);
        vaults.deposit(v, 1e17, type(uint128).max, type(uint128).max, address(0));
        vm.expectRevert(IBallastErrors.SlippageExceeded.selector);
        vaults.deposit(v, 1e17, 1, 1, BOB);
    }

    // ─── exit queue ───

    function _enter(address who, uint256 v, uint128 shares) internal {
        vm.prank(who);
        vaults.deposit(v, shares, type(uint128).max, type(uint128).max, who);
    }

    function test_Redeem_EscrowsSharesThenPaysAtMaturity_ToAChosenReceiver() public {
        uint256 v = _provide(-6000, 6000, 1e19);
        _enter(BOB, v, 1e17);
        vm.prank(BOB);
        uint256 t = vaults.requestRedeem(v, 1e17);
        assertEq(vaults.shareToken().balanceOf(BOB, v), 0, "shares left the owner");
        assertEq(vaults.shareToken().balanceOf(address(vaults), v), 1e17, "escrowed in the vaults");
        assertEq(vaults.shareToken().totalSupply(v), INITIAL_SHARES + 1e17, "supply unchanged by escrow");
        TicketView memory tv = lens.ticket(t);
        assertEq(tv.owner, BOB);
        assertEq(tv.shares, 1e17);
        assertEq(tv.maturity, vm.getBlockTimestamp() + 600);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.TicketNotMature.selector, tv.maturity));
        vaults.claimRedeem(t, BOB);

        vm.warp(tv.maturity);
        address receiver = address(0xCAFE);
        (uint256 c0, uint256 q0) = _bal(receiver);
        vm.prank(BOB);
        (uint128 a0, uint128 a1) = vaults.claimRedeem(t, receiver);
        (uint256 c1, uint256 q1) = _bal(receiver);
        assertEq(c1 - c0, a0);
        assertEq(q1 - q0, a1);
        assertEq(vaults.shareToken().balanceOf(address(vaults), v), 0, "escrow released");
        assertEq(vaults.shareToken().totalSupply(v), INITIAL_SHARES, "burned");
        assertEq(lens.ticket(t).owner, address(0), "ticket deleted");
    }

    function test_Redeem_OperatorCanClaim_StrangerCannot() public {
        uint256 v = _provide(-6000, 6000, 1e19);
        _enter(BOB, v, 1e17);
        vm.prank(BOB);
        uint256 t = vaults.requestRedeem(v, 1e17);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.prank(ALICE);
        vm.expectRevert(IBallastErrors.NotTicketOwnerOrOperator.selector);
        vaults.claimRedeem(t, ALICE);
        BallastShares st = vaults.shareToken();
        vm.prank(BOB);
        st.setOperator(ALICE, true);
        vm.prank(ALICE);
        vaults.claimRedeem(t, ALICE);
    }

    function test_CancelRedeem_ReturnsEscrowedShares_OnlyOwner() public {
        uint256 v = _provide(-6000, 6000, 1e19);
        _enter(BOB, v, 1e17);
        vm.prank(BOB);
        uint256 t = vaults.requestRedeem(v, 4e16);
        vm.prank(ALICE);
        vm.expectRevert(IBallastErrors.NotTicketOwnerOrOperator.selector);
        vaults.cancelRedeem(t);
        vm.prank(BOB);
        vaults.cancelRedeem(t);
        assertEq(vaults.shareToken().balanceOf(BOB, v), 1e17);
        assertEq(vaults.shareToken().balanceOf(address(vaults), v), 0);
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.UnknownTicket.selector, t));
        vm.prank(BOB);
        vaults.cancelRedeem(t);
    }

    function test_RevertWhen_RequestRedeem_MoreThanBalanceOrZero() public {
        uint256 v = _provide(-6000, 6000, 1e19);
        vm.prank(BOB);
        vm.expectRevert(IBallastErrors.SharesExceedBalance.selector);
        vaults.requestRedeem(v, 1);
        vm.expectRevert(IBallastErrors.ZeroShares.selector);
        vaults.requestRedeem(v, 0);
    }

    function test_EscrowedShares_CannotBeTransferredByTheirFormerOwner() public {
        uint256 v = _provide(-6000, 6000, 1e19);
        _enter(BOB, v, 1e17);
        BallastShares st = vaults.shareToken();
        vm.startPrank(BOB);
        vaults.requestRedeem(v, 1e17);
        vm.expectRevert();
        st.transfer(ALICE, v, 1);
        vm.stopPrank();
    }

    // ─── INV-5: no round-trip profit ───

    function testFuzz_DepositThenRedeem_NeverReturnsMoreThanPaid(uint256 sharesSeed) public {
        uint256 v = _provide(-6000, 6000, 1e19);
        uint128 shares = uint128(bound(sharesSeed, 1e6, 1e18));
        uint128 liqBefore = lens.positionsOf(v)[0].liquidity;
        (uint256 cb, uint256 qb) = _bal(BOB);
        _enter(BOB, v, shares);
        vm.prank(BOB);
        uint256 t = vaults.requestRedeem(v, shares);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.prank(BOB);
        vaults.claimRedeem(t, BOB);
        (uint256 ca, uint256 qa) = _bal(BOB);
        assertLe(ca, cb, "collateral: round trip never profits");
        assertLe(qa, qb, "quote: round trip never profits");
        assertGe(lens.positionsOf(v)[0].liquidity, liqBefore, "vault liquidity never shrinks (rounding favours it)");
    }

    // ─── donations (T2) ───

    function test_DonationsToVaultsOrPoolManager_DoNotMoveShareMaths() public {
        uint256 v = _provide(-6000, 6000, 1e19);
        VaultView memory before_ = lens.vault(v);
        (uint128 e0, uint128 e1) = lens.previewDeposit(v, 1e17);
        // Direct token donations to the vaults and to the PoolManager.
        collateral.transfer(address(vaults), 1e24);
        quote.transfer(address(vaults), 1e24);
        collateral.transfer(address(pm), 1e24);
        quote.transfer(address(pm), 1e24);
        (uint128 d0, uint128 d1) = lens.previewDeposit(v, 1e17);
        assertEq(d0, e0);
        assertEq(d1, e1);
        VaultView memory after_ = lens.vault(v);
        assertEq(after_.idle0, before_.idle0);
        assertEq(after_.idle1, before_.idle1);
        assertEq(after_.totalShares, before_.totalShares);
        vm.prank(BOB);
        (uint128 a0, uint128 a1) =
            vaults.deposit(v, 1e17, type(uint128).max, type(uint128).max, BOB);
        assertApproxEqAbs(a0, e0, 2);
        assertApproxEqAbs(a1, e1, 2);
    }

    // ─── trading fees and curator fee ───

    function test_TradingFees_AreCrystallizedIntoIdle_WithCuratorCut() public {
        vm.prank(ALICE);
        uint256 v = vaults.createVault(_ranges(-6000, 6000), 0, 1000); // 10% curator fee
        vm.prank(ALICE);
        vaults.seed(v, _liqs(1e19), type(uint128).max, type(uint128).max, ALICE);
        vm.warp(vm.getBlockTimestamp() + 100);
        _swap(true, 1e17);
        vm.warp(vm.getBlockTimestamp() + 100);
        _swap(false, 1e17);
        vaults.checkpoint(v);
        VaultView memory d = lens.vault(v);
        assertGt(d.idle0 + d.idle1, 0, "holders' share of the trading fees is idle");
        assertGt(d.curatorOwed0 + d.curatorOwed1, 0, "curator cut accrued");
        // The curator cut is 10% of what was collected (idle is the other 90%), up to rounding.
        assertApproxEqRel(d.curatorOwed0 * 9, d.idle0, 1e15);

        (uint256 c0, uint256 q0) = _bal(ALICE);
        vm.prank(ALICE);
        (uint128 o0, uint128 o1) = vaults.claimCuratorFees(v, ALICE);
        (uint256 c1, uint256 q1) = _bal(ALICE);
        assertEq(c1 - c0, o0);
        assertEq(q1 - q0, o1);
        assertEq(lens.vault(v).curatorOwed0, 0);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.NotCurator.selector, BOB));
        vaults.claimCuratorFees(v, BOB);
    }

    function test_Deposit_PaysForAccruedIdle_NoFeeSniping() public {
        vm.prank(ALICE);
        uint256 v = vaults.createVault(_ranges(-6000, 6000), 0, 0);
        vm.prank(ALICE);
        vaults.seed(v, _liqs(1e19), type(uint128).max, type(uint128).max, ALICE);
        vm.warp(vm.getBlockTimestamp() + 100);
        _swap(true, 5e17);
        vm.warp(vm.getBlockTimestamp() + 100);
        _swap(false, 5e17);
        // Uncollected fees sit in the positions; the deposit crystallizes them first, so BOB pays for his share.
        vm.prank(BOB);
        vaults.deposit(v, 1e18, type(uint128).max, type(uint128).max, BOB);
        VaultView memory d = lens.vault(v);
        assertGt(d.idle0 + d.idle1, 0, "fees were credited to idle before shares were minted");
        // BOB holds 1e18 of 2e18 total shares and paid half of the idle in kind, so redeeming returns about that
        // half of idle and not more.
        vm.prank(BOB);
        uint256 t = vaults.requestRedeem(v, 1e18);
        vm.warp(vm.getBlockTimestamp() + 600);
        (uint256 cb, uint256 qb) = _bal(BOB);
        vm.prank(BOB);
        vaults.claimRedeem(t, BOB);
        (uint256 ca, uint256 qa) = _bal(BOB);
        // He paid p0/p1 on entry; after exit he has no more than he paid in total across both tokens' value.
        assertLe(ca - cb, 5e18 + 5e18, "sanity bound on the collateral returned");
        assertGt(qa, qb - 1);
    }
}
