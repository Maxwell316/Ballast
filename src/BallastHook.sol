// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BandMath} from "./libraries/BandMath.sol";
import {ConfigLib} from "./libraries/ConfigLib.sol";
import {Observations} from "./libraries/Observations.sol";
import {StressMachine} from "./libraries/StressMachine.sol";
import {Transient} from "./libraries/Transient.sol";
import {IBallastPool} from "./interfaces/IBallastPool.sol";
import {Config, LockState, StressInfo} from "./types/Types.sol";

/// @title BallastHook (M2: pool binding, oracle, stress machine)
/// @notice Committed-liquidation-depth hook. M2 carries the validated immutable configuration, the five-flag
/// permission set, one-pool binding, hook-only liquidity (G-1), the tick-cumulative oracle and the lazily evaluated
/// stress machine. Vaults, shares and standby accounting arrive in later milestones.
/// @dev Inherits OpenZeppelin `BaseHook` (ADR-030), which validates the deployed address against
/// `getHookPermissions()` in its constructor. Configuration lives in immutables so the swap path never reads
/// configuration from storage.
///
/// Swaps are never blockable by Ballast logic (R-STR-10): `_beforeSwap` reverts only on the D-9 guard. Everything
/// else on that path is total: the oracle update cannot overflow inside the documented domain (MATH §4), the stress
/// transition is a pure total function (`StressMachine.next`), and no division has a variable divisor.
contract BallastHook is BaseHook, IBallastPool {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using Observations for Observations.Observation[];

    /// @dev Stress machine state that must persist between evaluations. One storage slot (8 + 40 + 40 + 8 bits).
    struct StressStorage {
        LockState state;
        uint40 stressStartedAt;
        uint40 belowExitSince;
        bool lockExpiryRecorded;
    }

    Currency private immutable _collateral;
    Currency private immutable _quote;
    address private immutable _sponsor;
    address private immutable _initializer;
    uint24 private immutable _fee;
    int24 private immutable _tickSpacing;
    uint16 private immutable _bandBps;
    uint16 private immutable _stressEnterBps;
    uint16 private immutable _stressExitBps;
    uint32 private immutable _anchorWindow;
    uint32 private immutable _shortWindow;
    uint32 private immutable _calmDuration;
    uint32 private immutable _maxStressLock;
    uint32 private immutable _exitNotice;
    uint32 private immutable _rerangeGrace;
    uint32 private immutable _maxAccrualInterval;
    uint16 private immutable _maxCuratorFeeBps;
    uint32 private immutable _observationInterval;
    uint16 private immutable _observationCardinality;
    uint128 private immutable _maxStandbyRate;
    /// @dev Stress thresholds in ticks, converted once from bps, rounded to nearest (R-STR-8, ADR-037).
    uint32 private immutable _enterTicks;
    uint32 private immutable _exitTicks;

    /// @dev The bound pool (R-POOL-1). Zero until bound.
    PoolId private _poolId;
    bool private _bound;
    bool private _collateralIs0;
    /// @dev Snapshots of the running accumulator, and its packed state (docs/MATH.md §4).
    Observations.Observation[] internal _observations;
    Observations.State internal _obs;
    StressStorage internal _stress;
    /// @dev Search cursors of the two TWAP windows (ADR-038); packed in one slot.
    Observations.Cursor private _anchorCursor;
    Observations.Cursor private _shortCursor;

    /// @param poolManager_ The v4 PoolManager.
    /// @param cfg Immutable configuration; validated by `ConfigLib.validate` (R-CFG-1).
    constructor(IPoolManager poolManager_, Config memory cfg) BaseHook(poolManager_) {
        ConfigLib.validate(cfg);
        _collateral = cfg.collateral;
        _quote = cfg.quote;
        _sponsor = cfg.sponsor;
        _initializer = cfg.initializer;
        _fee = cfg.fee;
        _tickSpacing = cfg.tickSpacing;
        _bandBps = cfg.bandBps;
        _stressEnterBps = cfg.stressEnterBps;
        _stressExitBps = cfg.stressExitBps;
        _anchorWindow = cfg.anchorWindow;
        _shortWindow = cfg.shortWindow;
        _calmDuration = cfg.calmDuration;
        _maxStressLock = cfg.maxStressLock;
        _exitNotice = cfg.exitNotice;
        _rerangeGrace = cfg.rerangeGrace;
        _maxAccrualInterval = cfg.maxAccrualInterval;
        _maxCuratorFeeBps = cfg.maxCuratorFeeBps;
        _observationInterval = cfg.observationInterval;
        _observationCardinality = cfg.observationCardinality;
        _maxStandbyRate = cfg.maxStandbyRate;
        _enterTicks = BandMath.bpsToTicksNearest(cfg.stressEnterBps);
        _exitTicks = BandMath.bpsToTicksNearest(cfg.stressExitBps);
    }

    /// @notice The five permissions Ballast needs and nothing else (D-5). No return-delta flags.
    /// @inheritdoc BaseHook
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory permissions)
    {
        permissions.beforeInitialize = true;
        permissions.afterInitialize = true;
        permissions.beforeAddLiquidity = true;
        permissions.beforeRemoveLiquidity = true;
        permissions.beforeSwap = true;
    }

    // ─── Hook callbacks ───

    /// @dev Binds the pool (R-POOL-1..3, R-POOL-6, ADR-014). Reverts for any other initializer, key or second pool.
    /// @custom:requirement R-POOL-1 R-POOL-2 R-POOL-3 R-POOL-6
    function _beforeInitialize(address sender, PoolKey calldata key, uint160)
        internal
        override
        returns (bytes4)
    {
        if (sender != _initializer) revert PoolInitializerOnly(sender);
        if (address(key.hooks) != address(this)) revert InvalidPoolKey();
        if (LPFeeLibrary.isDynamicFee(key.fee)) revert DynamicFeeUnsupported();
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) {
            revert NativeCurrencyUnsupported();
        }
        if (_bound) revert PoolAlreadyBound();
        if (key.fee != _fee || key.tickSpacing != _tickSpacing) revert InvalidPoolKey();

        bool collateralIs0 = false;
        if (key.currency0 == _collateral && key.currency1 == _quote) {
            collateralIs0 = true;
        } else if (!(key.currency0 == _quote && key.currency1 == _collateral)) {
            revert InvalidPoolKey();
        }
        _bound = true;
        _collateralIs0 = collateralIs0;
        _poolId = key.toId();
        return this.beforeInitialize.selector;
    }

    /// @dev Seeds observation 0 with the initial tick and the current time (R-POOL-4).
    /// @custom:requirement R-POOL-4
    function _afterInitialize(address, PoolKey calldata, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {
        Observations.initialize(_observations, _obs, _now(), tick, _observationCardinality);
        return this.afterInitialize.selector;
    }

    /// @dev Hook-only liquidity: reverts for every caller that reaches it. The hook's own `modifyLiquidity` calls
    /// never reach it because the PoolManager skips callbacks for self-calls (R-LIQ-4, verified in VERIFICATION F-3).
    /// @custom:requirement R-LIQ-1
    /// @custom:guarantee G-1
    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        revert ExternalLiquidityForbidden();
    }

    /// @dev See `_beforeAddLiquidity`.
    /// @custom:requirement R-LIQ-2
    /// @custom:guarantee G-1
    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        revert ExternalLiquidityForbidden();
    }

    /// @dev The only revert is the D-9 guard (R-TX-1, R-STR-10). Advances the oracle with the pre-swap tick, and
    /// evaluates stress when a snapshot was written (at most once per `observationInterval`, R-STR-7a).
    /// @custom:requirement R-TX-1 R-ORC-1 R-STR-7 R-STR-10
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (Transient.get(Transient.VAULT_OP)) revert VaultOpInSameTransaction();
        Transient.set(Transient.SWAPPED, true);

        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        if (Observations.update(_observations, _obs, _now(), tick, _observationInterval)) {
            _evaluateStress(tick);
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ─── Permissionless maintenance ───

    /// @inheritdoc IBallastPool
    function pokeStress() external {
        if (!_bound) revert PoolNotBound();
        (, int24 tick,,) = poolManager.getSlot0(_poolId);
        // Price changes only at swaps, so the current tick is also the tick over [lastSwapTs, now]: this accumulation
        // is exact (MATH §4), and it lets the oracle make progress during swap droughts.
        Observations.update(_observations, _obs, _now(), tick, _observationInterval);
        _evaluateStress(tick);
    }

    // ─── Views ───

    /// @inheritdoc IBallastPool
    function poolId() external view returns (PoolId) {
        return _poolId;
    }

    /// @inheritdoc IBallastPool
    function collateralIsCurrency0() external view returns (bool) {
        return _collateralIs0;
    }

    /// @inheritdoc IBallastPool
    function twapTick(uint32 window) external view returns (int24 tick, bool warm) {
        if (!_bound) revert PoolNotBound();
        (, int24 current,,) = poolManager.getSlot0(_poolId);
        return Observations.twapTick(_observations, _obs, _now(), window, current);
    }

    /// @inheritdoc IBallastPool
    function stressInfo() external view returns (StressInfo memory info) {
        if (!_bound) return info;
        (, int24 current,,) = poolManager.getSlot0(_poolId);
        Evaluation memory e = _previewStress(current, true);
        info = StressInfo({
            state: e.ns,
            oracleWarm: e.warm,
            lockActive: StressMachine.lockActive(e.ns, e.nc),
            stressStartedAt: e.nc.stressStartedAt,
            lockedUntil: uint40(StressMachine.lockedUntil(e.ns, e.nc)),
            anchorTick: e.anchor,
            shortTick: e.short
        });
    }

    /// @inheritdoc IBallastPool
    function lockState() external view returns (LockState state, uint40 lockedUntil) {
        if (!_bound) return (LockState.CALM, 0);
        (, int24 current,,) = poolManager.getSlot0(_poolId);
        Evaluation memory e = _previewStress(current, false);
        return (e.ns, uint40(StressMachine.lockedUntil(e.ns, e.nc)));
    }

    /// @inheritdoc IBallastPool
    function config() external view returns (Config memory) {
        return Config({
            collateral: _collateral,
            quote: _quote,
            sponsor: _sponsor,
            initializer: _initializer,
            fee: _fee,
            tickSpacing: _tickSpacing,
            bandBps: _bandBps,
            stressEnterBps: _stressEnterBps,
            stressExitBps: _stressExitBps,
            anchorWindow: _anchorWindow,
            shortWindow: _shortWindow,
            calmDuration: _calmDuration,
            maxStressLock: _maxStressLock,
            exitNotice: _exitNotice,
            rerangeGrace: _rerangeGrace,
            maxAccrualInterval: _maxAccrualInterval,
            maxCuratorFeeBps: _maxCuratorFeeBps,
            observationInterval: _observationInterval,
            observationCardinality: _observationCardinality,
            maxStandbyRate: _maxStandbyRate
        });
    }

    // ─── Stress evaluation ───

    /// @dev `block.timestamp` as uint40. SAFETY: a uint40 holds timestamps until the year 36,812; the oracle domain
    /// (docs/MATH.md §4) is far narrower, so the truncation is unreachable.
    function _now() internal view returns (uint40) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint40(block.timestamp);
    }

    /// @dev Result of one evaluation. `ns`/`nc` are the machine's new state and context.
    struct Evaluation {
        LockState ns;
        StressMachine.Ctx nc;
        bool lockJustExpired;
        bool warm;
        int24 anchor;
        int24 short;
        Observations.Cursor anchorCursor;
        Observations.Cursor shortCursor;
    }

    /// @dev Pure-read computation shared by the write path and the views, so a view always equals what the next
    /// evaluation would store (R-STR-7). When `full` is false and the oracle is cold, the TWAP lookups are skipped
    /// (the machine ignores them while cold, R-STR-6), which keeps the cold-start swap path cheap (ADR-038).
    function _previewStress(int24 currentTick, bool full)
        internal
        view
        returns (Evaluation memory e)
    {
        uint40 nowTs = _now();
        e.warm = Observations.isWarm(_observations, _obs, nowTs, _anchorWindow);
        e.anchorCursor = _anchorCursor;
        e.shortCursor = _shortCursor;
        if (e.warm || full) {
            (e.anchor,, e.anchorCursor) = Observations.twapTickHinted(
                _observations, _obs, nowTs, _anchorWindow, currentTick, e.anchorCursor
            );
            (e.short,, e.shortCursor) = Observations.twapTickHinted(
                _observations, _obs, nowTs, _shortWindow, currentTick, e.shortCursor
            );
        } else {
            e.anchor = currentTick;
            e.short = currentTick;
        }
        // Positive when the short TWAP is displaced in the liquidation direction (StressMachine docs).
        int256 dev = _collateralIs0
            ? int256(e.anchor) - int256(e.short)
            : int256(e.short) - int256(e.anchor);

        StressStorage memory st = _stress;
        StressMachine.Ctx memory c = StressMachine.Ctx({
            nowTs: nowTs,
            stressStartedAt: st.stressStartedAt,
            belowExitSince: st.belowExitSince,
            enterTicks: _enterTicks,
            exitTicks: _exitTicks,
            calmDuration: _calmDuration,
            maxStressLock: _maxStressLock,
            lockExpiryRecorded: st.lockExpiryRecorded
        });
        (e.ns, e.nc, e.lockJustExpired) = StressMachine.next(st.state, dev, e.warm, c);
    }

    /// @dev Stores the transition and the search cursors, and emits events (R-STR-5: `LockExpired` once).
    function _evaluateStress(int24 currentTick) internal {
        LockState old = _stress.state;
        Evaluation memory e = _previewStress(currentTick, false);
        _stress = StressStorage({
            state: e.ns,
            stressStartedAt: e.nc.stressStartedAt,
            belowExitSince: e.nc.belowExitSince,
            lockExpiryRecorded: e.nc.lockExpiryRecorded
        });
        if (e.warm) {
            _anchorCursor = e.anchorCursor;
            _shortCursor = e.shortCursor;
        }
        if (e.ns != old) {
            if (e.ns == LockState.STRESS) {
                emit StressEntered(e.anchor, e.short, e.nc.stressStartedAt);
            } else if (e.ns == LockState.RECOVERING) {
                emit StressRecovering(e.nc.nowTs);
            } else {
                emit StressExited(e.nc.nowTs);
            }
        }
        if (e.lockJustExpired) emit LockExpired(e.nc.nowTs);
    }

    // ─── Transient guards (D-9, R-TX-2, R-TX-3) ───

    /// @dev Marks the transaction as containing a vault operation and reverts if it already contained a swap.
    function _enterVaultOp() internal {
        if (Transient.get(Transient.SWAPPED)) revert SwapInSameTransaction();
        Transient.set(Transient.VAULT_OP, true);
    }

    /// @dev Non-reentrant lock, released at the end of the call (and in any case at the end of the transaction).
    modifier nonReentrant() {
        if (Transient.get(Transient.LOCK)) revert Reentrancy();
        Transient.set(Transient.LOCK, true);
        _;
        Transient.set(Transient.LOCK, false);
    }
}
