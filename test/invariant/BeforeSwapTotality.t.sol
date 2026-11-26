// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookFixture} from "../utils/HookFixture.sol";
import {ConfigFixture} from "../utils/ConfigFixture.sol";
import {BallastHookHarness} from "../utils/BallastHookHarness.sol";
import {Config, LockState} from "../../src/types/Types.sol";

/// @dev Drives the hook's `beforeSwap`, `pokeStress` and views through arbitrary pool states: the pool tick is
/// written straight into the PoolManager's slot0 (so MIN/MAX ticks and wild jumps are reachable without liquidity),
/// time advances by arbitrary amounts, and every call is wrapped so that a revert is counted rather than propagated.
contract TotalityHandler is Test {
    BallastHookHarness internal immutable hook;
    address internal immutable pm;
    PoolKey internal key;
    bytes32 internal immutable slot0Slot;
    int24 internal immutable spacing;

    uint256 public beforeSwapReverts;
    uint256 public pokeReverts;
    uint256 public viewReverts;
    uint256 public illegalTransitions;
    uint256 public calls;
    uint256 public stressSeen;
    uint256 public elapsed;
    uint256 internal constant MAX_ELAPSED = 1 << 34; // ~544 years: inside the documented oracle domain (MATH §4)
    LockState internal last;
    uint40 internal lastStart;

    constructor(BallastHookHarness h, address pm_, PoolKey memory k, PoolId id, int24 spacing_) {
        hook = h;
        pm = pm_;
        key = k;
        spacing = spacing_;
        slot0Slot = keccak256(abi.encode(PoolId.unwrap(id), bytes32(uint256(6))));
    }

    function _pickTick(uint256 seed) internal view returns (int24) {
        uint256 m = seed % 6;
        int24 lo = TickMath.minUsableTick(spacing);
        int24 hi = TickMath.maxUsableTick(spacing);
        if (m == 0) return TickMath.MIN_TICK;
        if (m == 1) return TickMath.MAX_TICK;
        if (m == 2) return lo;
        if (m == 3) return hi;
        return
            int24(
                int256((seed >> 8) % uint256(int256(TickMath.MAX_TICK) * 2 + 1)) + TickMath.MIN_TICK
            );
    }

    function _writeTick(int24 tick) internal {
        bytes32 v = vm.load(pm, slot0Slot);
        // slot0: sqrtPriceX96 (160) | tick (24) | protocolFee (24) | lpFee (24)
        uint256 low = uint256(v) >> 184 << 184;
        uint256 nv =
            low | (uint256(uint24(tick)) << 160) | uint256(TickMath.getSqrtPriceAtTick(tick));
        vm.store(pm, slot0Slot, bytes32(nv));
    }

    function _advance(uint256 seed) internal {
        uint256 m = seed % 7;
        uint256 dt = m == 0
            ? 0
            : m == 1 ? 1 : m == 2 ? 59 : m == 3 ? 60 : m == 4 ? 61 : (seed >> 8) % (1 << 26);
        if (elapsed + dt > MAX_ELAPSED) dt = 0;
        elapsed += dt;
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    function _legal(LockState from, LockState to) internal pure returns (bool) {
        // INV-12: CALM -> {CALM, STRESS}; STRESS -> {STRESS, RECOVERING, CALM (cold release)};
        // RECOVERING -> {RECOVERING, STRESS, CALM}.
        if (from == LockState.CALM) return to == LockState.CALM || to == LockState.STRESS;
        return true;
    }

    function _check() internal {
        LockState now_ = hook.stressStorage().state;
        uint40 start = hook.stressStorage().stressStartedAt;
        if (!_legal(last, now_)) ++illegalTransitions;
        // stressStartedAt changes only on CALM -> STRESS (R-STR-1/2) or when cleared by CALM.
        if (last != LockState.CALM && now_ != LockState.CALM && start != lastStart) {
            ++illegalTransitions;
        }
        if (now_ != LockState.CALM) ++stressSeen;
        last = now_;
        lastStart = start;
    }

    function swapStep(uint256 timeSeed, uint256 tickSeed, uint256 dirSeed) external {
        ++calls;
        _advance(timeSeed);
        _writeTick(_pickTick(tickSeed));
        bool z = dirSeed % 2 == 0;
        SwapParams memory p = SwapParams({
            zeroForOne: z,
            amountSpecified: -int256(1 + dirSeed % 1e18),
            sqrtPriceLimitX96: z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        vm.prank(pm);
        try hook.beforeSwap(address(this), key, p, "") {}
        catch {
            ++beforeSwapReverts;
        }
        _check();
    }

    function pokeStep(uint256 timeSeed, uint256 tickSeed) external {
        ++calls;
        _advance(timeSeed);
        _writeTick(_pickTick(tickSeed));
        try hook.pokeStress() {}
        catch {
            ++pokeReverts;
        }
        _check();
        // The view must agree with what the evaluation just stored (R-STR-7).
        try hook.lockState() returns (LockState s, uint40) {
            if (s != hook.stressStorage().state) ++illegalTransitions;
        } catch {
            ++viewReverts;
        }
    }

    function viewStep(uint256 timeSeed, uint256 tickSeed) external {
        ++calls;
        _advance(timeSeed);
        _writeTick(_pickTick(tickSeed));
        try hook.stressInfo() {}
        catch {
            ++viewReverts;
        }
        try hook.twapTick(60) {}
        catch {
            ++viewReverts;
        }
    }
}

/// @notice R-STR-10: `beforeSwap` can revert only for the D-9 guard; the oracle update, the evaluation and the
/// transition are total over the documented domain, including MIN/MAX ticks, zero/huge time steps and every state.
/// @custom:requirement R-STR-10 R-STR-6 R-ORC-1
/// @custom:invariant INV-12
/// @custom:requirement R-ORC-9
contract BeforeSwapTotalityTest is HookFixture {
    TotalityHandler internal handler;

    function setUp() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
        handler = new TotalityHandler(hook, address(pm), key, pid, cfg.tickSpacing);
        targetContract(address(handler));
    }

    /// @notice The handler can actually reach the stress states (otherwise the invariants would be vacuous).
    function test_Handler_ReachesStressStates() public {
        // dt = 60 s (timeSeed % 7 == 3); alternate MAX_TICK / MIN_TICK so TWAPs swing in both directions.
        for (uint256 i; i < 140; ++i) {
            handler.swapStep(3, i % 2 == 0 ? 1 : 0, i);
        }
        assertGt(handler.stressSeen(), 0, "never left CALM");
        assertEq(handler.beforeSwapReverts(), 0);
        assertEq(handler.illegalTransitions(), 0);
    }

    function invariant_BeforeSwapNeverRevertsOutsideTheGuard() public view {
        assertEq(handler.beforeSwapReverts(), 0, "beforeSwap reverted");
        assertEq(handler.pokeReverts(), 0, "pokeStress reverted");
        assertEq(handler.viewReverts(), 0, "a view reverted");
    }

    function invariant_OnlyLegalStressTransitions() public view {
        assertEq(handler.illegalTransitions(), 0, "illegal transition or view/state mismatch");
    }
}

/// @notice Same handler, but the fuzzer controls whole sequences and the starting pool (both collateral sides, both
/// configs, extreme initial ticks), which the invariant runner does not vary.
/// @custom:requirement R-STR-10
contract BeforeSwapTotalityFuzzTest is HookFixture {
    /// forge-config: default.fuzz.runs = 300
    /// forge-config: ci.fuzz.runs = 3000
    function testFuzz_ArbitrarySequences_NeverRevert(
        bool c0,
        bool prodLike,
        uint8 startPick,
        uint256[24] memory seeds
    ) public {
        int24 start = startPick % 3 == 0
            ? TickMath.minUsableTick(60)
            : startPick % 3 == 1 ? TickMath.maxUsableTick(60) : int24(0);
        _setUpDefault(c0, prodLike ? ConfigFixture.prodLike() : ConfigFixture.compressed(), start);
        TotalityHandler handler = new TotalityHandler(hook, address(pm), key, pid, cfg.tickSpacing);
        for (uint256 i; i + 2 < seeds.length; i += 3) {
            uint256 kind = seeds[i] % 3;
            if (kind == 0) handler.swapStep(seeds[i + 1], seeds[i + 2], seeds[i]);
            else if (kind == 1) handler.pokeStep(seeds[i + 1], seeds[i + 2]);
            else handler.viewStep(seeds[i + 1], seeds[i + 2]);
        }
        assertEq(handler.beforeSwapReverts() + handler.pokeReverts() + handler.viewReverts(), 0);
        assertEq(handler.illegalTransitions(), 0);
    }
}
