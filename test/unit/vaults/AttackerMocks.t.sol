// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Matrix, C0Before, C1After} from "../../utils/Matrix.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {BallastStandby} from "../../../src/BallastStandby.sol";
import {LockState, Range, StandbyInfo, VaultView} from "../../../src/types/Types.sol";

/// @notice The attacker mocks of the M8 plan beyond reentrancy (which `ReentrancyAndEdges.t.sol` covers with hostile
/// tokens, sponsors and receivers): a token that refuses a payout (T13), donations of tokens, PoolManager claims and
/// shares to the hook and the vaults (T2, T9), and a router that spams dust and oversized hook data. Both orderings.
/// @custom:requirement R-LIQ-1 R-SBY-6
abstract contract AttackerMocksBase is Matrix {
    address internal constant BLOCKED = address(0xB10C);
    address internal constant FRIEND = address(0xF41E);

    function setUp() public {
        _setUpMatrix(ConfigFixture.compressed(), 0);
    }

    // ─── T13: a payout the token refuses ───

    /// @notice A receiver that the token blocks makes the whole claim revert: the ticket, the shares in escrow and the
    /// pool liquidity are exactly as before, and the owner retries with another receiver (chosen at claim time, ADR-016).
    function test_T13_BlockedReceiver_RevertsTheWholeClaim_AndARetryToAnotherReceiverPays() public {
        uint256 v = _provide(-6000, 6000, 1e19);
        uint256 id = vaults.requestRedeem(v, 2e17);
        vm.warp(vm.getBlockTimestamp() + 601);
        MockBlock(address(collateral)).setBlocked(BLOCKED, true);
        MockBlock(address(quote)).setBlocked(BLOCKED, true);

        uint128 liqBefore = lens.positionsOf(v)[0].liquidity;
        uint256 supplyBefore = vaults.shareToken().totalSupply(v);
        uint256 escrowBefore = vaults.shareToken().balanceOf(address(vaults), v);
        vm.expectRevert();
        vaults.claimRedeem(id, BLOCKED);
        assertEq(lens.ticket(id).owner, address(this), "the ticket is intact");
        assertEq(lens.positionsOf(v)[0].liquidity, liqBefore, "no liquidity left the pool");
        assertEq(vaults.shareToken().totalSupply(v), supplyBefore, "no share burned");
        assertEq(
            vaults.shareToken().balanceOf(address(vaults), v), escrowBefore, "the escrow is intact"
        );

        uint256 c0 = collateral.balanceOf(FRIEND);
        uint256 q0 = quote.balanceOf(FRIEND);
        vaults.claimRedeem(id, FRIEND);
        assertGt(
            collateral.balanceOf(FRIEND) - c0 + quote.balanceOf(FRIEND) - q0, 0, "the retry paid"
        );
        assertEq(lens.ticket(id).owner, address(0));
    }

    /// @notice The same for the curator's fees: a refused payout leaves the owed balance untouched.
    function test_T13_BlockedReceiver_DoesNotLoseTheCuratorsFees() public {
        Range[] memory r = new Range[](1);
        r[0] = Range(-6000, 6000);
        uint256 v = vaults.createVault(r, 0, 1000);
        uint128[] memory l = new uint128[](1);
        l[0] = 1e19;
        vaults.seed(v, l, type(uint128).max, type(uint128).max, address(this));
        _swap(true, 1e17);
        _swap(false, 5e16);
        vaults.checkpoint(v); // crystallise the trading fees; the curator's 10% is now owed
        VaultView memory owed = lens.vault(v);
        assertGt(uint256(owed.curatorOwed0) + owed.curatorOwed1, 0, "fees are owed");
        MockBlock(address(collateral)).setBlocked(BLOCKED, true);
        MockBlock(address(quote)).setBlocked(BLOCKED, true);
        vm.expectRevert();
        vaults.claimCuratorFees(v, BLOCKED);
        VaultView memory after_ = lens.vault(v);
        assertEq(after_.curatorOwed0, owed.curatorOwed0);
        assertEq(after_.curatorOwed1, owed.curatorOwed1);
        vaults.claimCuratorFees(v, FRIEND);
        assertEq(lens.vault(v).curatorOwed0, 0);
        assertEq(lens.vault(v).curatorOwed1, 0);
    }

    // ─── T2, T9: donations ───

    function _swapKeepingClaims(bool sellCollateral, uint256 amountIn) internal {
        bool zeroForOne = sellCollateral == collateralIs0;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Tokens sent to the hook, vaults, standby, share token and PoolManager; PoolManager claims sent to the hook,
    /// vaults and standby; shares sent to the hook and to the vaults (the escrow account): none of it moves a ledger, a
    /// preview, the depth, the fund, a reward or a payout. Accounting reads internal ledgers and PoolManager deltas,
    /// never balances. Everything is compared exactly, before and after the donations.
    function test_Donations_TokensClaimsAndShares_MoveNoAccounting() public {
        uint256 v = _provide(-6000, 6000, 1e19);
        vaults.setCommitment(v, 3e17);
        BallastStandby sb = BallastStandby(address(vaults.standby()));
        quote.mint(ConfigFixture.SPONSOR, 1e24);
        vm.startPrank(ConfigFixture.SPONSOR);
        quote.approve(address(sb), type(uint256).max);
        sb.fundStandby(1e18);
        sb.setStandbyRate(1e12);
        vm.stopPrank();
        // A sale that keeps its proceeds as PoolManager claims: the claims to donate. Then a checkpoint, so the ledgers
        // already include the sale's fees.
        _swapKeepingClaims(true, 1e17);
        vaults.checkpoint(v);
        uint256 qid = uint256(uint160(address(quote)));
        uint256 claims = pm.balanceOf(address(this), qid);
        assertGt(claims, 0, "the sale produced claims to donate");

        VaultView memory b0 = lens.vault(v);
        StandbyInfo memory f0 = sb.standbyInfo();
        (uint128 e0, uint128 e1) = lens.previewDeposit(v, 1e17);
        (uint128 r0, uint128 r1) = lens.previewRedeem(v, 1e17);
        uint256 committed = lens.committedDepth();
        uint256 live = lens.liveDepth(750, 600);
        uint256 sbClaims = pm.balanceOf(address(sb), qid);

        // Donate: tokens to five contracts, claims to three, shares to two.
        address[5] memory targets = [
            address(hook), address(vaults), address(sb), address(vaults.shareToken()), address(pm)
        ];
        for (uint256 i; i < targets.length; ++i) {
            collateral.transfer(targets[i], 1e21);
            quote.transfer(targets[i], 1e21);
        }
        pm.transfer(address(hook), qid, claims / 3);
        pm.transfer(address(vaults), qid, claims / 3);
        pm.transfer(address(sb), qid, claims / 3);
        vaults.shareToken().transfer(address(hook), v, 1e15);
        vaults.shareToken().transfer(address(vaults), v, 1e15);

        VaultView memory b1 = lens.vault(v);
        assertEq(b1.totalShares, b0.totalShares, "supply");
        assertEq(b1.idle0, b0.idle0, "idle0");
        assertEq(b1.idle1, b0.idle1, "idle1");
        assertEq(b1.curatorOwed0, b0.curatorOwed0, "owed0");
        assertEq(b1.curatorOwed1, b0.curatorOwed1, "owed1");
        assertEq(b1.commitment, b0.commitment, "commitment");
        StandbyInfo memory f1 = sb.standbyInfo();
        assertEq(f1.fundBalance, f0.fundBalance, "the fund is a ledger, not a balance");
        assertEq(f1.totalCredited, f0.totalCredited);
        assertEq(
            pm.balanceOf(address(sb), qid),
            sbClaims + claims / 3,
            "donated claims sit beside the fund, unspent"
        );
        (uint128 e0b, uint128 e1b) = lens.previewDeposit(v, 1e17);
        (uint128 r0b, uint128 r1b) = lens.previewRedeem(v, 1e17);
        assertEq(e0b, e0, "previewDeposit0");
        assertEq(e1b, e1, "previewDeposit1");
        assertEq(r0b, r0, "previewRedeem0");
        assertEq(r1b, r1, "previewRedeem1");
        assertEq(lens.committedDepth(), committed, "committed depth");
        assertEq(lens.liveDepth(750, 600), live, "live depth");

        // The reward is the closed form on the commitment, paid from the fund ledger, whatever claims sit beside it.
        vm.warp(vm.getBlockTimestamp() + 100);
        vaults.checkpoint(v);
        uint256 paid = f1.fundBalance - sb.standbyInfo().fundBalance;
        assertEq(
            paid, uint256(3e17) * 100 * 1e12 / 1e18, "reward from the ledger: 3e17 x 100 s x rate"
        );

        // A redeem pays the previewed slice of the ledger; none of the donated tokens comes out.
        vm.prank(ConfigFixture.SPONSOR);
        sb.setStandbyRate(0); // so that no reward lands between the preview and the claim
        uint256 id = vaults.requestRedeem(v, 1e17);
        vm.warp(vm.getBlockTimestamp() + 601);
        (uint128 p0, uint128 p1) = lens.previewRedeem(v, 1e17);
        uint256 cBefore = collateral.balanceOf(address(this));
        uint256 qBefore = quote.balanceOf(address(this));
        vaults.claimRedeem(id, address(this));
        (uint256 got0, uint256 got1) = collateralIs0
            ? (
                collateral.balanceOf(address(this)) - cBefore,
                quote.balanceOf(address(this)) - qBefore
            )
            : (
                quote.balanceOf(address(this)) - qBefore,
                collateral.balanceOf(address(this)) - cBefore
            );
        assertEq(got0, p0, "currency0 payout is the previewed slice");
        assertEq(got1, p1, "currency1 payout is the previewed slice");
        assertLt(got0, 1e21, "none of the donated tokens left with the redeemer");
        assertLt(got1, 1e21);
    }

    // ─── a griefing router ───

    /// @notice Dust swaps in one block, dust swaps every block, and a swap carrying 20 kB of hook data change nothing
    /// that matters: the machine stays in CALM, at most one snapshot is written per interval, and the hook's own gas
    /// stays inside its budget.
    function test_GriefingRouter_DustAndOversizedHookData_DoNotMoveTheMachine() public {
        _provide(-12_000, 12_000, 1e19);
        for (uint256 i; i < 64; ++i) {
            vm.warp(vm.getBlockTimestamp() + 60);
            _swap(false, 1e6);
        }
        uint256 snaps = hook.obsLength();
        // Twenty dust swaps in a single block write at most one snapshot between them.
        vm.warp(vm.getBlockTimestamp() + 60);
        for (uint256 i; i < 20; ++i) {
            _swap(i % 2 == 0, 1e6);
        }
        assertLe(hook.obsLength(), snaps + 1, "one snapshot per interval, however many swaps");
        // A swap with 20 kB of hook data: the hook ignores it.
        bytes memory junk = new bytes(20_000);
        bool zeroForOne = !collateralIs0;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1e6),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            junk
        );
        assertLt(hook.lastBeforeSwapGas(), 200_000, "hook gas stays bounded whatever the hook data");
        // Poking between a router's own legs is harmless too.
        _swap(true, 1e6);
        hook.pokeStress();
        _swap(false, 1e6);
        assertEq(uint8(hook.stressStorage().state), uint8(LockState.CALM));
    }
}

interface MockBlock {
    function setBlocked(address who, bool blocked) external;
}

contract AttackerMocksTest_C0Before is AttackerMocksBase, C0Before {}

contract AttackerMocksTest_C1After is AttackerMocksBase, C1After {}
