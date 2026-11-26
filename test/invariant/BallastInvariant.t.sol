// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Position as PoolPosition} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookFixture} from "../utils/HookFixture.sol";
import {ConfigFixture} from "../utils/ConfigFixture.sol";
import {BallastHookHarness} from "../utils/BallastHookHarness.sol";
import {BallastVaultsHarness} from "../utils/BallastVaultsHarness.sol";
import {MockERC20} from "../utils/MockERC20.sol";
import {BallastLens} from "../../src/periphery/BallastLens.sol";
import {BallastStandby} from "../../src/BallastStandby.sol";
import {BallastShares} from "../../src/BallastShares.sol";
import {LockState, Range, StandbyInfo, StressInfo, VaultView} from "../../src/types/Types.sol";

/// @dev Actions of the invariant run: several depositors, the vaults' curators, one trader and the sponsor act on a
/// real hook, vaults, standby and PoolManager. Every action is wrapped, so reverts are normal; ghost variables record
/// violations that cannot be read back from state (exits while locked, illegal transitions, re-arming).
contract BallastHandler is Test {
    BallastHookHarness internal hook;
    BallastVaultsHarness internal vaults;
    BallastLens internal lens;
    BallastStandby internal standby;
    BallastShares internal shares;
    MockERC20 internal collateral;
    MockERC20 internal quote;
    PoolSwapTest internal router;
    PoolKey internal key;
    bool internal collateralIs0;

    address[3] public depositors = [address(0xD001), address(0xD002), address(0xD003)];
    address public trader = address(0x7AD3);
    address internal sponsor = ConfigFixture.SPONSOR;
    address internal seeder;

    uint256 public vaultCount;
    uint256[] internal tickets;
    uint256 public fundedTotal;

    // ghosts
    uint256 public exitsWhileLocked;
    uint256 public illegalTransitions;
    uint256 public rearmed;
    uint256 public successfulExits;
    uint256 public stressEpisodes;
    uint256 public deposits;
    uint256 public reranges;
    LockState internal lastState;
    uint40 internal lastStart;
    bool internal lastLockActive;

    constructor(
        BallastHookHarness hook_,
        BallastVaultsHarness vaults_,
        BallastLens lens_,
        MockERC20 collateral_,
        MockERC20 quote_,
        PoolSwapTest router_,
        PoolKey memory key_,
        bool c0,
        uint256 vaultCount_,
        uint256 funded_
    ) {
        hook = hook_;
        vaults = vaults_;
        lens = lens_;
        standby = BallastStandby(address(vaults_.standby()));
        shares = vaults_.shareToken();
        collateral = collateral_;
        quote = quote_;
        router = router_;
        key = key_;
        collateralIs0 = c0;
        vaultCount = vaultCount_;
        fundedTotal = funded_;
        seeder = msg.sender; // the test contract that seeded the vaults holds their initial shares
        for (uint256 i; i < depositors.length; ++i) {
            _fund(depositors[i]);
        }
        _fund(trader);
    }

    function _fund(address who) internal {
        collateral.mint(who, 1e27);
        quote.mint(who, 1e27);
        vm.startPrank(who);
        collateral.approve(address(vaults), type(uint256).max);
        quote.approve(address(vaults), type(uint256).max);
        collateral.approve(address(router), type(uint256).max);
        quote.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function holders() external view returns (address[] memory h) {
        h = new address[](7);
        for (uint256 i; i < 3; ++i) {
            h[i] = depositors[i];
        }
        h[3] = seeder;
        h[4] = address(vaults); // escrow
        h[5] = address(0); // burned minimum
        h[6] = trader;
    }

    function _vaultId(uint256 seed) internal view returns (uint256) {
        return (seed % vaultCount) + 1;
    }

    function _observe() internal {
        StressInfo memory info = hook.stressInfo();
        LockState s = hook.stressStorage().state;
        // Legal transitions only: CALM->STRESS, STRESS->RECOVERING, RECOVERING->STRESS|CALM (INV-12).
        if (s != lastState) {
            bool ok = (lastState == LockState.CALM && s == LockState.STRESS)
                || (lastState == LockState.STRESS && s == LockState.RECOVERING)
                || (lastState == LockState.RECOVERING
                    && (s == LockState.STRESS || s == LockState.CALM));
            if (!ok) ++illegalTransitions;
            if (lastState == LockState.CALM && s == LockState.STRESS) ++stressEpisodes;
        }
        // No re-arming: within one episode, once the lock was seen inactive while not CALM it stays inactive.
        if (s != LockState.CALM && lastState != LockState.CALM && info.stressStartedAt == lastStart)
        {
            if (!lastLockActive && info.lockActive) ++rearmed;
        }
        lastState = s;
        lastStart = info.stressStartedAt;
        lastLockActive = info.lockActive;
    }

    // ─── actions ───

    function deposit(uint256 actor, uint256 vseed, uint256 amount) external {
        address a = depositors[actor % 3];
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 s = uint128(bound(amount, 1e6, 5e17));
        vm.prank(a);
        try vaults.deposit(_vaultId(vseed), s, type(uint128).max, type(uint128).max, a) {
            ++deposits;
        } catch {}
        _observe();
    }

    function requestRedeem(uint256 actor, uint256 vseed, uint256 amount) external {
        address a = depositors[actor % 3];
        uint256 v = _vaultId(vseed);
        uint256 bal = shares.balanceOf(a, v);
        if (bal == 0) return;
        vm.prank(a);
        // forge-lint: disable-next-line(unsafe-typecast)
        try vaults.requestRedeem(v, uint128(bound(amount, 1, bal))) returns (uint256 id) {
            tickets.push(id);
        } catch {}
        _observe();
    }

    function cancelRedeem(uint256 idx) external {
        if (tickets.length == 0) return;
        uint256 id = tickets[idx % tickets.length];
        address owner = lens.ticket(id).owner;
        if (owner == address(0)) return;
        vm.prank(owner);
        try vaults.cancelRedeem(id) {} catch {}
        _observe();
    }

    function claimRedeem(uint256 idx) external {
        if (tickets.length == 0) return;
        uint256 id = tickets[idx % tickets.length];
        address owner = lens.ticket(id).owner;
        if (owner == address(0)) return;
        vm.prank(owner);
        try vaults.claimRedeem(id, owner) {
            ++successfulExits;
            // `claimRedeem` evaluates stress itself first, so compare with the state after the call's own evaluation.
            if (hook.stressInfo().lockActive) ++exitsWhileLocked;
        } catch {}
        _observe();
    }

    function rerange(uint256 vseed, uint256 lo, uint256 width, uint256 liq) external {
        uint256 v = _vaultId(vseed);
        address curator = lens.vault(v).curator;
        // forge-lint: disable-start(unsafe-typecast)
        int24 l = -int24(int256(bound(lo, 1, 100))) * 60;
        int24 h = l + int24(int256(bound(width, 2, 200))) * 60;
        // forge-lint: disable-end(unsafe-typecast)
        Range[] memory r = new Range[](1);
        r[0] = Range(l, h);
        uint128[] memory liqs = new uint128[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        liqs[0] = uint128(bound(liq, 1e17, 5e18));
        vm.prank(curator);
        try vaults.rerange(v, r, liqs) {
            ++reranges;
        } catch {}
        _observe();
    }

    function setCommitment(uint256 vseed, uint256 amount) external {
        uint256 v = _vaultId(vseed);
        address curator = lens.vault(v).curator;
        vm.prank(curator);
        // forge-lint: disable-next-line(unsafe-typecast)
        try vaults.setCommitment(v, uint128(bound(amount, 0, 6e17))) {} catch {}
        _observe();
    }

    function checkpoint(uint256 vseed) external {
        try vaults.checkpoint(_vaultId(vseed)) {} catch {}
        _observe();
    }

    function swap(bool sell, uint256 amount, uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 400));
        _swap(sell, bound(amount, 1e9, 4e17));
        _observe();
    }

    /// @dev A liquidation-sized sell followed by time at the lower price, so the short TWAP can leave the anchor and
    /// stress can engage; the run then continues through whatever the fuzzer chooses.
    function crash(uint256 amount, uint256 dwell) external {
        _swap(true, bound(amount, 2e17, 6e17));
        vm.warp(vm.getBlockTimestamp() + bound(dwell, 60, 900));
        try hook.pokeStress() {} catch {}
        _observe();
    }

    function _swap(bool sell, uint256 a) internal {
        bool zeroForOne = sell == collateralIs0;
        vm.prank(trader);
        try router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(a),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 1, 1800));
        try hook.pokeStress() {} catch {}
        _observe();
    }

    function fund(uint256 amount) external {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 a = uint128(bound(amount, 1e3, 1e12));
        quote.mint(sponsor, a);
        vm.startPrank(sponsor);
        quote.approve(address(standby), type(uint256).max);
        try standby.fundStandby(a) {
            fundedTotal += a;
        } catch {}
        vm.stopPrank();
    }

    function setRate(uint256 rate) external {
        vm.prank(sponsor);
        // forge-lint: disable-next-line(unsafe-typecast)
        try standby.setStandbyRate(uint128(bound(rate, 0, 1e12))) {} catch {}
    }
}

/// @notice Handler-based invariants over the whole system (M5/M8): INV-1, INV-2, INV-3, INV-4, INV-6, INV-8, INV-12.
/// @custom:invariant INV-1 INV-2 INV-3 INV-4 INV-6 INV-8 INV-12
contract BallastInvariantTest is HookFixture {
    using StateLibrary for IPoolManager;

    BallastHandler internal handler;
    uint256 internal constant SEEDED_VAULTS = 3;

    function setUp() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
        MockERC20 q = MockERC20(address(quote));
        q.mint(ConfigFixture.SPONSOR, 1e18);
        for (uint256 i; i < SEEDED_VAULTS; ++i) {
            int24 half = int24(int256(1980 * (i + 1)));
            _provideWithFee(-half, half, uint128(2e18 + i * 1e18), uint16(i * 500));
        }
        // A funded, running standby from the start so that accrual is exercised on every path.
        BallastStandby sb = BallastStandby(address(vaults.standby()));
        vm.startPrank(ConfigFixture.SPONSOR);
        quote.approve(address(sb), type(uint256).max);
        sb.fundStandby(1e15);
        sb.setStandbyRate(1e9);
        vm.stopPrank();
        handler = new BallastHandler(
            hook,
            vaults,
            lens,
            MockERC20(address(collateral)),
            MockERC20(address(quote)),
            swapRouter,
            key,
            collateralIs0,
            SEEDED_VAULTS,
            1e15
        );
        // The seeding account (this) keeps its initial shares; hand the handler's actors a share of each vault.
        for (uint256 v = 1; v <= SEEDED_VAULTS; ++v) {
            for (uint256 i; i < 3; ++i) {
                vaults.shareToken().transfer(handler.depositors(i), v, 1e17);
            }
        }
        targetContract(address(handler));
    }

    /// @notice Reachability: a scripted run through the handler's own actions reaches stress and a release, so the
    /// invariants above are checked over states that include the lock (not only calm ones).
    function test_Handler_CanReachStressAndRelease() public {
        for (uint256 i; i < 8; ++i) {
            handler.warp(1800);
        }
        handler.requestRedeem(0, 0, 1e16); // ticket matures long before the crash
        handler.warp(1800);
        handler.crash(6e17, 400);
        handler.warp(120);
        assertGe(handler.stressEpisodes(), 1, "stress was reached");
        handler.claimRedeem(0); // refused while locked
        assertEq(handler.successfulExits(), 0, "no exit while locked");
        for (uint256 i; i < 40; ++i) {
            handler.warp(600);
        }
        handler.claimRedeem(0);
        assertEq(handler.successfulExits(), 1, "the exit clears after calm");
        assertEq(handler.exitsWhileLocked(), 0);
        assertEq(handler.illegalTransitions(), 0);
    }

    function _provideWithFee(int24 lo, int24 hi, uint128 liq, uint16 feeBps) internal {
        Range[] memory r = new Range[](1);
        r[0] = Range(lo, hi);
        uint256 v = vaults.createVault(r, 0, feeBps);
        uint128[] memory l = new uint128[](1);
        l[0] = liq;
        vaults.seed(v, l, type(uint128).max, type(uint128).max, address(this));
    }

    function _poolLiq(uint256 v, uint256 slot, int24 lo, int24 hi) internal view returns (uint128) {
        bytes32 k =
            PoolPosition.calculatePositionKey(address(vaults), lo, hi, bytes32((v << 8) | slot));
        return IPoolManager(address(pm)).getPositionLiquidity(pid, k);
    }

    /// INV-1 and INV-2: every position is the vaults', owned by no one else, and the recorded liquidity equals the pool's.
    function invariant_PositionsAreOwnedByTheVaults_AndRecordedLiquidityMatchesThePool()
        public
        view
    {
        uint256 n = lens.vaultCount();
        for (uint256 v = 1; v <= n; ++v) {
            for (uint256 s; s < lens.positionsOf(v).length; ++s) {
                (int24 lo, int24 hi, uint128 liq) = _position(v, s);
                assertEq(_poolLiq(v, s, lo, hi), liq, "INV-2");
                bytes32 hk =
                    PoolPosition.calculatePositionKey(address(hook), lo, hi, bytes32((v << 8) | s));
                assertEq(
                    IPoolManager(address(pm)).getPositionLiquidity(pid, hk),
                    0,
                    "INV-1: hook owns nothing"
                );
            }
        }
    }

    function _position(uint256 v, uint256 s) internal view returns (int24, int24, uint128) {
        return (
            lens.positionsOf(v)[s].tickLower,
            lens.positionsOf(v)[s].tickUpper,
            lens.positionsOf(v)[s].liquidity
        );
    }

    /// INV-3 (inequality form): the PoolManager claims the vaults hold cover every vault's idle plus curator-owed
    /// balance, and the standby holds claims for its fund.
    function invariant_ClaimsCoverIdleOwedAndFund() public view {
        uint256 n = lens.vaultCount();
        uint256 s0;
        uint256 s1;
        for (uint256 v = 1; v <= n; ++v) {
            VaultView memory d = lens.vault(v);
            s0 += uint256(d.idle0) + d.curatorOwed0;
            s1 += uint256(d.idle1) + d.curatorOwed1;
        }
        (uint256 c0, uint256 c1) = collateralIs0
            ? (uint256(uint160(address(collateral))), uint256(uint160(address(quote))))
            : (uint256(uint160(address(quote))), uint256(uint160(address(collateral))));
        assertGe(pm.balanceOf(address(vaults), c0), s0, "INV-3 currency0");
        assertGe(pm.balanceOf(address(vaults), c1), s1, "INV-3 currency1");
        StandbyInfo memory info = vaults.standby().standbyInfo();
        assertGe(
            pm.balanceOf(address(vaults.standby()), uint256(uint160(address(quote)))),
            info.fundBalance,
            "INV-3 fund"
        );
    }

    /// INV-4: total supply equals the sum of the balances of every account that can hold shares.
    function invariant_ShareSupplyEqualsTheSumOfBalances() public view {
        address[] memory h = handler.holders();
        uint256 n = lens.vaultCount();
        for (uint256 v = 1; v <= n; ++v) {
            uint256 sum;
            for (uint256 i; i < h.length; ++i) {
                sum += vaults.shareToken().balanceOf(h[i], v);
            }
            assertEq(sum, vaults.shareToken().totalSupply(v), "INV-4");
        }
    }

    /// INV-6: no exit succeeded while the lock was active (the claim evaluates stress first).
    function invariant_NoExitWhileTheLockIsActive() public view {
        assertEq(handler.exitsWhileLocked(), 0, "INV-6");
    }

    /// INV-12: only legal transitions, and the lock never re-arms inside an episode.
    function invariant_StressMachineMakesOnlyLegalTransitions() public view {
        assertEq(handler.illegalTransitions(), 0, "INV-12 transitions");
        assertEq(handler.rearmed(), 0, "INV-12 no re-arming");
    }

    /// INV-8 (part): credited rewards never exceed what was funded.
    function invariant_CreditedRewardsNeverExceedFunding() public view {
        StandbyInfo memory info = vaults.standby().standbyInfo();
        assertLe(info.totalCredited, handler.fundedTotal(), "INV-8");
        assertEq(
            uint256(info.fundBalance) + info.totalCredited,
            handler.fundedTotal(),
            "fund conservation"
        );
    }

    /// Meaningfulness: the run exercises stress, exits and re-ranges (reported by `-vv`, asserted loosely).
    function afterInvariant() public view {
        console2.log("stress episodes", handler.stressEpisodes());
        console2.log("exits", handler.successfulExits());
        console2.log("deposits", handler.deposits());
        console2.log("reranges", handler.reranges());
        console2.log("credited", vaults.standby().standbyInfo().totalCredited);
    }
}
