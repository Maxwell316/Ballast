// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BallastDepth} from "./BallastDepth.sol";
import {BallastShares} from "./BallastShares.sol";
import {BallastStandby} from "./BallastStandby.sol";
import {BandMath} from "./libraries/BandMath.sol";
import {RewardMath} from "./libraries/RewardMath.sol";
import {Transient} from "./libraries/Transient.sol";
import {VaultMath} from "./libraries/VaultMath.sol";
import {IBallastHook} from "./interfaces/IBallastHook.sol";
import {IBallastStandby} from "./interfaces/IBallastStandby.sol";
import {IBallastVaults} from "./interfaces/IBallastVaults.sol";
import {
    EXIT_BUCKETS,
    INITIAL_SHARES,
    MAX_POSITIONS,
    MAX_VAULTS,
    MINIMUM_SHARES
} from "./types/Constants.sol";
import {
    Config,
    CuratorRecord,
    LockState,
    Position,
    PositionView,
    Range,
    StressInfo,
    TicketView,
    VaultView
} from "./types/Types.sol";

/// @title BallastVaults
/// @notice Custody contract of a Ballast pool (ADR-045). It owns every position in the pool, the vault shares
/// (ERC-6909), the PoolManager claims (idle balances, curator fees, standby fund) and all vault operations.
/// @dev Deployed before the hook, at the address the hook's constructor is given (ADR-050); the hook admits only that
/// address in `beforeAdd/RemoveLiquidity` (G-1). Calls into the hook are limited to `enterVaultOp()`,
/// `evaluateStress()` and `stressInfo()`; after construction the hook never calls back. Every entrypoint that takes a
/// vault id needs an existing vault, and vaults are created only after the pool is bound, which requires the hook
/// to have code. No owner, admin, proxy or `delegatecall`.
contract BallastVaults is IUnlockCallback, IBallastVaults {
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice The caller of `unlockCallback` was not the PoolManager.
    error NotPoolManager();

    IPoolManager public immutable poolManager;
    IBallastHook public immutable hook;
    /// @notice The standby pool this contract created (ADR-046). Vaults call it only through `accrue`.
    IBallastStandby public immutable standby;
    /// @notice The share token this contract created (ADR-050). Only this contract can mint, burn or escrow.
    BallastShares public immutable shareToken;
    /// @notice The stateless depth calculator this contract created (ADR-050).
    BallastDepth public immutable depthCalc;
    /// @notice `keccak256(abi.encode(config))`; the hook checks it at construction (ADR-050).
    bytes32 public immutable configHash;
    Currency private immutable _collateral;
    Currency private immutable _quote;
    uint24 private immutable _fee;
    int24 private immutable _tickSpacing;
    uint32 private immutable _exitNotice;
    uint32 private immutable _rerangeGrace;
    uint32 private immutable _maxAccrualInterval;
    uint16 private immutable _maxCuratorFeeBps;
    /// @dev Band length in ticks, converted once from `bandBps` (round toward less depth, ADR-035).
    uint24 private immutable _bandTicks;
    /// @dev Currencies are ordered by address in a PoolKey, so this is fixed by the configuration.
    bool private immutable _collateralIs0;
    PoolId private immutable _poolId;

    /// @param poolManager_ The v4 PoolManager.
    /// @param hook_ The hook this contract is bound to; deployed afterwards at this (mined) address (ADR-050).
    /// @param cfg The hook's validated configuration.
    constructor(IPoolManager poolManager_, IBallastHook hook_, Config memory cfg) {
        poolManager = poolManager_;
        hook = hook_;
        _collateral = cfg.collateral;
        _quote = cfg.quote;
        _fee = cfg.fee;
        _tickSpacing = cfg.tickSpacing;
        _exitNotice = cfg.exitNotice;
        _rerangeGrace = cfg.rerangeGrace;
        _maxAccrualInterval = cfg.maxAccrualInterval;
        _maxCuratorFeeBps = cfg.maxCuratorFeeBps;
        configHash = keccak256(abi.encode(cfg));
        standby = IBallastStandby(address(new BallastStandby(poolManager_, address(this), cfg)));
        shareToken = new BallastShares();
        depthCalc = new BallastDepth();
        _bandTicks = BandMath.bpsToTicksDown(cfg.bandBps);
        bool c0 = Currency.unwrap(cfg.collateral) < Currency.unwrap(cfg.quote);
        _collateralIs0 = c0;
        PoolKey memory k = PoolKey({
            currency0: c0 ? cfg.collateral : cfg.quote,
            currency1: c0 ? cfg.quote : cfg.collateral,
            fee: cfg.fee,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(address(hook_))
        });
        _poolId = k.toId();
    }

    /// @dev Non-reentrant lock held in transient storage, released at the end of the call (R-TX-3).
    modifier nonReentrant() {
        _lock();
        _;
        _release();
    }

    function _lock() private {
        if (Transient.get(Transient.LOCK)) revert Reentrancy();
        Transient.set(Transient.LOCK, true);
    }

    function _release() private {
        Transient.set(Transient.LOCK, false);
    }

    /// @dev `block.timestamp` as uint40 (unreachable truncation: a uint40 holds timestamps to the year 36,812).
    function _now() internal view returns (uint40) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint40(block.timestamp);
    }

    /// @dev Reverts until the pool has been initialized (the hook's `beforeInitialize` bound it).
    function _requireBound() internal view {
        // slither-disable-next-line unused-return
        (uint160 sqrtP,,,) = poolManager.getSlot0(_poolId);
        if (sqrtP == 0) revert PoolNotBound();
    }

    // ─── Vault storage ───

    /// @dev Vault state, packed in five slots (ADR-024). Positions live in `_positions`, shares in the ERC-6909
    /// ledger, counters in `_records`.
    struct VaultData {
        address curator;
        uint16 curatorFeeBps;
        uint8 positionCount;
        uint40 pendingCommitmentAt;
        uint128 commitment;
        uint128 pendingCommitment;
        uint128 idle0;
        uint128 idle1;
        uint128 owed0;
        uint128 owed1;
        uint40 lastCheckpoint;
        uint40 breachSince;
        uint40 coverageLostSince;
        uint128 lastDepthSample;
    }

    /// @dev A redeem ticket. `bucketEpoch` locates its aggregate in the exit buckets (ADR-045).
    struct Ticket {
        address owner;
        uint40 maturity;
        uint16 vaultId;
        uint128 shares;
        uint40 bucketEpoch;
    }

    /// @dev Aggregate of open ticket shares whose maturity falls in epoch `epoch` (width `_bucketWidth()`).
    struct Bucket {
        uint40 epoch;
        uint128 shares;
    }

    /// @dev Per-operation working set, so deltas and samples are computed once per unlock.
    struct Env {
        uint160 sqrtP;
        int24 tick;
        int24 anchor;
        bool calm;
        uint40 episode;
        uint128 committed;
        uint128 sample;
        uint256 f0;
        uint256 f1;
    }

    /// @dev Payload of `unlock`. One shape for every operation keeps the callback a plain dispatcher.
    struct OpCtx {
        uint8 op;
        uint256 v;
        address caller;
        address receiver;
        int24 anchor;
        bool calm;
        uint40 episode;
        uint256 a;
        bytes extra;
    }

    /// @dev Most rounding dust one re-range can leave per currency: each removal rounds down and each addition rounds
    /// up by at most one wei, so at most 2 * MAX_POSITIONS wei, doubled for margin (ADR-055).
    uint256 internal constant RERANGE_DUST_CAP = 4 * MAX_POSITIONS;

    uint8 internal constant OP_SEED = 1;
    uint8 internal constant OP_DEPOSIT = 2;
    uint8 internal constant OP_REDEEM = 3;
    uint8 internal constant OP_RERANGE = 4;
    uint8 internal constant OP_DEPLOY = 5;
    uint8 internal constant OP_CHECKPOINT = 6;
    uint8 internal constant OP_CLAIM_FEES = 8;

    mapping(uint256 => VaultData) internal _vaults;
    mapping(uint256 => Position[]) internal _positions;
    mapping(uint256 => CuratorRecord) internal _records;
    mapping(uint256 => uint40) internal _lastEpisode;
    mapping(uint256 => Ticket) internal _tickets;
    mapping(uint256 => Bucket[EXIT_BUCKETS]) internal _buckets;
    mapping(uint256 => uint128) internal _maturedEscrow;
    uint256 internal _vaultCount;
    uint256 internal _ticketCount;

    // ─── Vault lifecycle ───

    /// @inheritdoc IBallastVaults
    /// @custom:requirement R-VLT-1
    function createVault(Range[] calldata ranges, uint128 commitment, uint16 curatorFeeBps)
        external
        nonReentrant
        returns (uint256 vaultId)
    {
        _requireBound();
        if (_vaultCount >= MAX_VAULTS) revert TooManyVaults();
        if (curatorFeeBps > _maxCuratorFeeBps) revert InvalidCuratorFee(curatorFeeBps);
        _validateRanges(ranges);
        vaultId = ++_vaultCount;
        VaultData storage vd = _vaults[vaultId];
        vd.curator = msg.sender;
        vd.curatorFeeBps = curatorFeeBps;
        vd.commitment = commitment;
        // SAFETY: `_validateRanges` bounds the length by MAX_POSITIONS (8).
        // forge-lint: disable-next-line(unsafe-typecast)
        vd.positionCount = uint8(ranges.length);
        for (uint256 i; i < ranges.length; ++i) {
            _positions[vaultId].push(Position(ranges[i].tickLower, ranges[i].tickUpper, 0));
        }
        emit VaultCreated(vaultId, msg.sender, commitment, curatorFeeBps);
    }

    /// @inheritdoc IBallastVaults
    /// @custom:requirement R-VLT-5 R-VLT-2 R-TX-2 R-TX-3
    /// @custom:guarantee G-2
    function seed(
        uint256 vaultId,
        uint128[] calldata liquidities,
        uint128 amount0Max,
        uint128 amount1Max,
        address receiver
    ) external nonReentrant returns (uint128 amount0, uint128 amount1) {
        hook.enterVaultOp();
        VaultData storage vd = _curatorVault(vaultId);
        if (_supplyOf(vaultId) != 0) revert VaultAlreadySeeded();
        if (liquidities.length != vd.positionCount) revert InvalidLiquidities();
        if (receiver == address(0)) revert InvalidReceiver();
        StressInfo memory e = _requireCalm();
        OpCtx memory c = _ctx(OP_SEED, vaultId, e);
        c.receiver = receiver;
        c.extra = abi.encode(
            liquidities, uint128(INITIAL_SHARES - MINIMUM_SHARES), amount0Max, amount1Max
        );
        return _run(c);
    }

    /// @inheritdoc IBallastVaults
    /// @custom:requirement R-VLT-2 R-VLT-3 R-VLT-4 R-TX-2 R-SBY-5
    /// @custom:guarantee G-2
    function deposit(
        uint256 vaultId,
        uint128 shares,
        uint128 amount0Max,
        uint128 amount1Max,
        address receiver
    ) external nonReentrant returns (uint128 amount0, uint128 amount1) {
        hook.enterVaultOp();
        _vault(vaultId);
        _requireSeeded(vaultId);
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert InvalidReceiver();
        StressInfo memory e = _requireCalm();
        OpCtx memory c = _ctx(OP_DEPOSIT, vaultId, e);
        c.receiver = receiver;
        c.extra = abi.encode(new uint128[](0), shares, amount0Max, amount1Max);
        return _run(c);
    }

    /// @inheritdoc IBallastVaults
    /// @custom:requirement R-VLT-7
    function requestRedeem(uint256 vaultId, uint128 shares)
        external
        nonReentrant
        returns (uint256 ticketId)
    {
        _vault(vaultId);
        if (shares == 0) revert ZeroShares();
        if (shareToken.balanceOf(msg.sender, vaultId) < shares) revert SharesExceedBalance();
        // Escrow is a plain move of shares to this contract's own balance; supply is unchanged, so escrowed shares
        // keep earning and bearing risk (R-VLT-7). The former owner can no longer transfer them.
        shareToken.move(msg.sender, address(this), vaultId, shares);
        uint40 maturity = _now() + _exitNotice;
        uint40 epoch = maturity / _bucketWidth();
        ticketId = ++_ticketCount;
        // SAFETY: vaultId <= MAX_VAULTS (16).
        // forge-lint: disable-next-line(unsafe-typecast)
        _tickets[ticketId] = Ticket(msg.sender, maturity, uint16(vaultId), shares, epoch);
        _bucketAdd(vaultId, epoch, shares);
        emit RedeemRequested(ticketId, vaultId, msg.sender, shares, maturity);
    }

    /// @inheritdoc IBallastVaults
    /// @custom:requirement R-VLT-9
    function cancelRedeem(uint256 ticketId) external nonReentrant {
        Ticket memory t = _tickets[ticketId];
        if (t.owner == address(0)) revert UnknownTicket(ticketId);
        if (msg.sender != t.owner) revert NotTicketOwnerOrOperator();
        delete _tickets[ticketId];
        _bucketRemove(t.vaultId, t.bucketEpoch, t.shares);
        shareToken.move(address(this), t.owner, t.vaultId, t.shares);
        emit RedeemCancelled(ticketId);
    }

    /// @inheritdoc IBallastVaults
    /// @custom:requirement R-VLT-8 R-TX-2 R-STR-4 R-STR-7
    /// @custom:guarantee G-3 G-4
    function claimRedeem(uint256 ticketId, address receiver)
        external
        nonReentrant
        returns (uint128 amount0, uint128 amount1)
    {
        hook.enterVaultOp();
        Ticket memory t = _tickets[ticketId];
        if (t.owner == address(0)) revert UnknownTicket(ticketId);
        if (msg.sender != t.owner && !shareToken.isOperator(t.owner, msg.sender)) {
            revert NotTicketOwnerOrOperator();
        }
        if (receiver == address(0)) revert InvalidReceiver();
        // Stress is evaluated first so that no separate poke is needed to release a lock (R-STR-7b).
        StressInfo memory e = _evalFull();
        if (e.lockActive) {
            revert StressLockActive(e.lockedUntil);
        }
        if (_now() < t.maturity) revert TicketNotMature(t.maturity);
        OpCtx memory c = _ctx(OP_REDEEM, t.vaultId, e);
        c.receiver = receiver;
        c.a = ticketId;
        return _run(c);
    }

    /// @inheritdoc IBallastVaults
    /// @custom:requirement R-VLT-10 R-VLT-14 R-TX-2 R-SBY-5
    function rerange(uint256 vaultId, Range[] calldata newRanges, uint128[] calldata liquidities)
        external
        nonReentrant
    {
        hook.enterVaultOp();
        _curatorVault(vaultId);
        _requireSeeded(vaultId);
        if (liquidities.length != newRanges.length) revert InvalidLiquidities();
        _validateRanges(newRanges);
        StressInfo memory e = _requireCalm();
        OpCtx memory c = _ctx(OP_RERANGE, vaultId, e);
        c.extra = abi.encode(newRanges, liquidities);
        _run(c);
    }

    /// @inheritdoc IBallastVaults
    /// @custom:requirement R-VLT-11 R-TX-2
    function deployIdle(uint256 vaultId, Range calldata range, uint128 liquidity)
        external
        nonReentrant
    {
        hook.enterVaultOp();
        _curatorVault(vaultId);
        _requireSeeded(vaultId);
        if (liquidity == 0) revert InvalidLiquidities();
        Range[] memory one = new Range[](1);
        one[0] = range;
        _validateRanges(one);
        OpCtx memory c = _ctx(OP_DEPLOY, vaultId, _evalFull());
        c.extra = abi.encode(range, liquidity);
        _run(c);
    }

    /// @inheritdoc IBallastVaults
    /// @custom:requirement R-VLT-12 R-SBY-5
    function setCommitment(uint256 vaultId, uint128 newCommitment) external nonReentrant {
        VaultData storage vd = _curatorVault(vaultId);
        // Accrue at the old commitment before it changes (R-SBY-5): the standard checkpoint, through one unlock.
        if (_supplyOf(vaultId) != 0) _checkpointVault(vaultId);
        if (newCommitment >= vd.commitment) {
            vd.commitment = newCommitment;
            vd.pendingCommitment = 0;
            vd.pendingCommitmentAt = 0;
            emit CommitmentChanged(vaultId, newCommitment, false, _now());
        } else {
            vd.pendingCommitment = newCommitment;
            vd.pendingCommitmentAt = _now() + _exitNotice;
            emit CommitmentChanged(vaultId, newCommitment, true, vd.pendingCommitmentAt);
        }
    }

    /// @inheritdoc IBallastVaults
    /// @custom:requirement R-FEE-3
    function claimCuratorFees(uint256 vaultId, address to)
        external
        nonReentrant
        returns (uint128 amount0, uint128 amount1)
    {
        _curatorVault(vaultId);
        if (to == address(0)) revert InvalidReceiver();
        OpCtx memory c;
        c.op = OP_CLAIM_FEES;
        c.v = vaultId;
        c.receiver = to;
        return _run(c);
    }

    // ─── Permissionless maintenance ───

    /// @inheritdoc IBallastVaults
    /// @custom:requirement R-SBY-3 R-FEE-1
    function checkpoint(uint256 vaultId) external nonReentrant {
        _vault(vaultId);
        _requireSeeded(vaultId);
        _checkpointVault(vaultId);
    }

    function _checkpointVault(uint256 vaultId) private {
        _run(_ctx(OP_CHECKPOINT, vaultId, _evalFull()));
    }

    // ─── Unlock callback ───

    /// @notice PoolManager callback. Only the PoolManager can call it, and only `unlock` calls made by this
    /// contract carry data it understands.
    /// @dev Virtual so that the test harness can add a stand-in operation (ADR-044).
    function unlockCallback(bytes calldata data) external virtual returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        OpCtx memory c = abi.decode(data, (OpCtx));
        (uint128 a0, uint128 a1) = _dispatch(c);
        return abi.encode(a0, a1);
    }

    function _dispatch(OpCtx memory c) internal returns (uint128, uint128) {
        if (c.op == OP_SEED || c.op == OP_DEPOSIT) return _opAdd(c);
        if (c.op == OP_REDEEM) return _opRedeem(c);
        if (c.op == OP_RERANGE) return _opRerange(c);
        if (c.op == OP_DEPLOY) return _opDeploy(c);
        if (c.op == OP_CHECKPOINT) return _opCheckpoint(c);
        return _opClaimFees(c);
    }

    function _run(OpCtx memory c) internal returns (uint128 a0, uint128 a1) {
        (a0, a1) = abi.decode(poolManager.unlock(abi.encode(c)), (uint128, uint128));
    }

    // ─── Operations (run inside the unlock) ───

    /// @dev Seed and deposit share one body (ADR-050): a seed supplies per-position liquidity and mints the initial
    /// shares; a deposit scales every position and the idle slices by `shares / supply`, rounding up (R-VLT-3, INV-5).
    function _opAdd(OpCtx memory c) internal returns (uint128, uint128) {
        bool seeding = c.op == OP_SEED;
        (uint128[] memory liqs, uint128 shares, uint128 max0, uint128 max1) =
            abi.decode(c.extra, (uint128[], uint128, uint128, uint128));
        Env memory env = seeding ? _env(c) : _prepare(c);
        uint256 supply = seeding ? 0 : _supplyOf(c.v);
        Position[] storage ps = _positions[c.v];
        uint256 p0;
        uint256 p1;
        for (uint256 i; i < ps.length; ++i) {
            uint128 dl =
                seeding ? liqs[i] : _u128(VaultMath.ceilShare(ps[i].liquidity, shares, supply));
            if (dl == 0) continue;
            (int128 a0, int128 a1) =
                _modify(c.v, i, ps[i].tickLower, ps[i].tickUpper, int256(uint256(dl)), env);
            ps[i].liquidity += dl;
            p0 += _neg(a0);
            p1 += _neg(a1);
        }
        VaultData storage vd = _vaults[c.v];
        uint256 s0;
        uint256 s1;
        if (seeding) {
            if (p0 == 0 && p1 == 0) revert InvalidLiquidities();
        } else {
            s0 = VaultMath.ceilShare(vd.idle0, shares, supply);
            s1 = VaultMath.ceilShare(vd.idle1, shares, supply);
            vd.idle0 += _u128(s0);
            vd.idle1 += _u128(s1);
            p0 += s0;
            p1 += s1;
        }
        if (p0 > max0 || p1 > max1) revert SlippageExceeded();
        _settleIn(_c0(), c.caller, p0);
        _settleIn(_c1(), c.caller, p1);
        _toClaims(_c0(), s0);
        _toClaims(_c1(), s1);
        _flush(c.v, env);
        if (seeding) {
            shares = uint128(INITIAL_SHARES - MINIMUM_SHARES);
            shareToken.mint(address(0), c.v, MINIMUM_SHARES);
            _measure(c.v, env);
            vd.lastCheckpoint = _now();
            vd.lastDepthSample = env.sample;
            _updateCoverage(c.v, env);
        } else {
            // Scaled sample: after the deposit the depth is at least proportional (ceil), so scaling down is
            // conservative.
            vd.lastDepthSample =
                _u128(FixedPointMathLib.fullMulDiv(env.sample, supply + shares, supply));
        }
        emit Deposited(c.v, c.caller, c.receiver, shares, _u128(p0), _u128(p1));
        shareToken.mint(c.receiver, c.v, shares);
        return (_u128(p0), _u128(p1));
    }

    function _opRedeem(OpCtx memory c) internal returns (uint128, uint128) {
        Ticket memory t = _tickets[c.a];
        Env memory env = _prepare(c);
        uint256 supply = _supplyOf(c.v);
        Position[] storage ps = _positions[c.v];
        uint256 r0;
        uint256 r1;
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].liquidity == 0) continue;
            // Rounds down: the leaving holder receives at most a proportional slice (R-VLT-8, INV-5).
            uint128 dl = _u128(VaultMath.floorShare(ps[i].liquidity, t.shares, supply));
            if (dl == 0) continue;
            (int128 a0, int128 a1) =
                _modify(c.v, i, ps[i].tickLower, ps[i].tickUpper, -int256(uint256(dl)), env);
            ps[i].liquidity -= dl;
            r0 += uint128(a0);
            r1 += uint128(a1);
        }
        VaultData storage vd = _vaults[c.v];
        uint256 s0 = VaultMath.floorShare(vd.idle0, t.shares, supply);
        uint256 s1 = VaultMath.floorShare(vd.idle1, t.shares, supply);
        vd.idle0 -= _u128(s0);
        vd.idle1 -= _u128(s1);
        _fromClaims(_c0(), s0);
        _fromClaims(_c1(), s1);
        _flush(c.v, env);
        delete _tickets[c.a];
        _bucketRemove(c.v, t.bucketEpoch, t.shares);
        shareToken.burn(address(this), c.v, t.shares);
        vd.lastDepthSample =
            _u128(FixedPointMathLib.fullMulDiv(env.sample, supply - t.shares, supply));
        _takeOut(_c0(), c.receiver, r0 + s0);
        _takeOut(_c1(), c.receiver, r1 + s1);
        emit RedeemClaimed(c.a, c.v, c.receiver, _u128(r0 + s0), _u128(r1 + s1));
        return (_u128(r0 + s0), _u128(r1 + s1));
    }

    function _opRerange(OpCtx memory c) internal returns (uint128, uint128) {
        (Range[] memory ranges, uint128[] memory liqs) = abi.decode(c.extra, (Range[], uint128[]));
        Env memory env = _env(c);
        _crystallize(c.v, env);
        _flush(c.v, env);
        _measure(c.v, env);
        uint128 before_ = env.sample;
        VaultData storage vd = _vaults[c.v];
        Position[] storage ps = _positions[c.v];

        int256 net0;
        int256 net1;
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].liquidity == 0) continue;
            (int128 a0, int128 a1) = _modify(
                c.v, i, ps[i].tickLower, ps[i].tickUpper, -int256(uint256(ps[i].liquidity)), env
            );
            net0 += a0;
            net1 += a1;
        }
        delete _positions[c.v];
        uint256 largest;
        for (uint256 i; i < ranges.length; ++i) {
            _positions[c.v].push(Position(ranges[i].tickLower, ranges[i].tickUpper, liqs[i]));
            if (liqs[i] > liqs[largest]) largest = i;
            if (liqs[i] == 0) continue;
            (int128 a0, int128 a1) = _modify(
                c.v, i, ranges[i].tickLower, ranges[i].tickUpper, int256(uint256(liqs[i])), env
            );
            net0 += a0;
            net1 += a1;
        }
        // SAFETY: `_validateRanges` bounded the length by MAX_POSITIONS (8).
        // forge-lint: disable-next-line(unsafe-typecast)
        vd.positionCount = uint8(ranges.length);

        // Dust rule (ADR-046): the net of removals and additions settles against idle. If idle cannot cover a
        // shortfall, the largest new position is shrunk by the minimal liquidity that does.
        (net0, net1) = _coverShortfall(c.v, largest, net0, net1, env);
        _settleNet(_c0(), net0, vd.idle0, c.v, true);
        _settleNet(_c1(), net1, vd.idle1, c.v, false);

        _measure(c.v, env);
        if (env.committed < vd.commitment) {
            revert CoverageBelowCommitment(env.committed, vd.commitment);
        }
        _accrue(c.v, env, before_);
        ++_records[c.v].rerangeCount;
        emit Reranged(c.v, vd.positionCount, before_, env.sample);
        return (0, 0);
    }

    function _opDeploy(OpCtx memory c) internal returns (uint128, uint128) {
        (Range memory range, uint128 liq) = abi.decode(c.extra, (Range, uint128));
        Env memory env = _prepare(c);
        Position[] storage ps = _positions[c.v];
        uint256 slot = ps.length;
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].tickLower == range.tickLower && ps[i].tickUpper == range.tickUpper) {
                slot = i;
                break;
            }
        }
        if (slot == ps.length) {
            if (slot >= MAX_POSITIONS) revert TooManyPositions();
            ps.push(Position(range.tickLower, range.tickUpper, 0));
            // SAFETY: slot < MAX_POSITIONS (8).
            // forge-lint: disable-next-line(unsafe-typecast)
            _vaults[c.v].positionCount = uint8(ps.length);
        }
        (int128 a0, int128 a1) =
            _modify(c.v, slot, range.tickLower, range.tickUpper, int256(uint256(liq)), env);
        ps[slot].liquidity += liq;
        VaultData storage vd = _vaults[c.v];
        uint256 o0 = _neg(a0);
        uint256 o1 = _neg(a1);
        if (o0 > vd.idle0 || o1 > vd.idle1) revert InsufficientIdle();
        vd.idle0 -= _u128(o0);
        vd.idle1 -= _u128(o1);
        _fromClaims(_c0(), o0);
        _fromClaims(_c1(), o1);
        _flush(c.v, env);
        _measure(c.v, env);
        vd.lastDepthSample = env.sample;
        emit IdleDeployed(c.v, range.tickLower, range.tickUpper, liq);
        return (_u128(o0), _u128(o1));
    }

    function _opCheckpoint(OpCtx memory c) internal returns (uint128, uint128) {
        _prepare(c);
        return (0, 0);
    }

    function _opClaimFees(OpCtx memory c) internal returns (uint128, uint128) {
        VaultData storage vd = _vaults[c.v];
        uint128 o0 = vd.owed0;
        uint128 o1 = vd.owed1;
        vd.owed0 = 0;
        vd.owed1 = 0;
        _fromClaims(_c0(), o0);
        _fromClaims(_c1(), o1);
        _takeOut(_c0(), c.receiver, o0);
        _takeOut(_c1(), c.receiver, o1);
        emit CuratorFeeClaimed(c.v, c.receiver, o0, o1);
        return (o0, o1);
    }

    /// @dev Shared prelude of every share- or position-changing operation after the first deposit: crystallize
    /// trading fees into the vault (R-FEE-1), measure depth, accrue standby for the elapsed interval (R-SBY-5).
    function _prepare(OpCtx memory c) internal returns (Env memory env) {
        env = _env(c);
        _crystallize(c.v, env);
        _flush(c.v, env);
        _measure(c.v, env);
        _accrue(c.v, env, type(uint128).max);
    }

    // ─── Re-range settlement ───

    /// @dev If a currency's net debt exceeds idle, removes the minimal liquidity from the largest new position so the
    /// removal covers the shortfall. At most one shrink per currency; reverts `InsufficientIdle` if that fails.
    function _coverShortfall(uint256 v, uint256 largest, int256 net0, int256 net1, Env memory env)
        internal
        returns (int256, int256)
    {
        for (uint256 k; k < 2; ++k) {
            uint256 idle = k == 0 ? _vaults[v].idle0 : _vaults[v].idle1;
            int256 net = k == 0 ? net0 : net1;
            if (net >= 0 || uint256(-net) <= idle) continue;
            if (uint256(-net) - idle > RERANGE_DUST_CAP) revert InsufficientIdle();
            (int128 a0, int128 a1) = _shrink(v, largest, uint256(-net) - idle, k == 0, env);
            net0 += a0;
            net1 += a1;
            net = k == 0 ? net0 : net1;
            if (net < 0 && uint256(-net) > idle) revert InsufficientIdle();
        }
        return (net0, net1);
    }

    function _shrink(uint256 v, uint256 slot, uint256 shortfall, bool token0, Env memory env)
        internal
        returns (int128, int128)
    {
        Position storage p = _positions[v][slot];
        uint256 dl = depthCalc.shrinkLiquidity(
            p.tickLower, p.tickUpper, p.liquidity, env.sqrtP, shortfall, token0
        );
        if (dl == 0) revert InsufficientIdle();
        // SAFETY: `shrinkLiquidity` returns dl < p.liquidity <= 2^128.
        // forge-lint: disable-next-line(unsafe-typecast)
        p.liquidity -= uint128(dl);
        return _modify(v, slot, p.tickLower, p.tickUpper, -int256(dl), env);
    }

    /// @dev Settles the net balance of one currency against the vault's idle claims.
    function _settleNet(Currency cur, int256 net, uint128 idleNow, uint256 v, bool is0) internal {
        VaultData storage vd = _vaults[v];
        if (net > 0) {
            uint256 up = uint256(net);
            _toClaims(cur, up);
            if (is0) vd.idle0 = idleNow + _u128(up);
            else vd.idle1 = idleNow + _u128(up);
        } else if (net < 0) {
            uint256 down = uint256(-net);
            _fromClaims(cur, down);
            if (is0) vd.idle0 = idleNow - _u128(down);
            else vd.idle1 = idleNow - _u128(down);
        }
    }

    // ─── Accounting helpers ───

    function _vault(uint256 vaultId) internal view returns (VaultData storage vd) {
        vd = _vaults[vaultId];
        if (vd.curator == address(0)) revert UnknownVault(vaultId);
    }

    /// @dev The vault, reverting unless it exists and the caller is its curator.
    function _curatorVault(uint256 vaultId) internal view returns (VaultData storage vd) {
        vd = _vault(vaultId);
        if (msg.sender != vd.curator) revert NotCurator(msg.sender);
    }

    function _requireSeeded(uint256 vaultId) private view {
        if (_supplyOf(vaultId) == 0) revert VaultNotSeeded();
    }

    function _supplyOf(uint256 vaultId) internal view returns (uint256) {
        return shareToken.totalSupply(vaultId);
    }

    function _c0() internal view returns (Currency) {
        return _collateralIs0 ? _collateral : _quote;
    }

    function _c1() internal view returns (Currency) {
        return _collateralIs0 ? _quote : _collateral;
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: _c0(),
            currency1: _c1(),
            fee: _fee,
            tickSpacing: _tickSpacing,
            hooks: IHooks(address(hook))
        });
    }

    uint8 private constant CASH_SETTLE_IN = 0;
    uint8 private constant CASH_TAKE_OUT = 1;
    uint8 private constant CASH_TO_CLAIMS = 2;
    uint8 private constant CASH_FROM_CLAIMS = 3;

    /// @dev The single settlement routine (one copy of the `CurrencySettler` calls keeps the runtime small, ADR-046).
    /// Zero amounts are skipped. `who` is the payer for `CASH_SETTLE_IN` and the receiver for `CASH_TAKE_OUT`.
    function _cash(uint8 mode, Currency cur, address who, uint256 amount) private {
        if (amount == 0) return;
        if (mode == CASH_SETTLE_IN) cur.settle(poolManager, who, amount, false);
        else if (mode == CASH_TAKE_OUT) cur.take(poolManager, who, amount, false);
        else if (mode == CASH_TO_CLAIMS) cur.take(poolManager, address(this), amount, true);
        else cur.settle(poolManager, address(this), amount, true);
    }

    function _settleIn(Currency cur, address payer, uint256 amount) internal {
        _cash(CASH_SETTLE_IN, cur, payer, amount);
    }

    function _takeOut(Currency cur, address to, uint256 amount) internal {
        _cash(CASH_TAKE_OUT, cur, to, amount);
    }

    function _toClaims(Currency cur, uint256 amount) internal {
        _cash(CASH_TO_CLAIMS, cur, address(0), amount);
    }

    function _fromClaims(Currency cur, uint256 amount) internal {
        _cash(CASH_FROM_CLAIMS, cur, address(0), amount);
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        // SAFETY: callers pass token amounts bounded by PoolManager int128 deltas or by uint128 ledger entries.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }

    function _neg(int128 x) internal pure returns (uint256) {
        // SAFETY: callers use it only on deltas that are non-positive by construction (an addition costs tokens).
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(uint128(-x));
    }

    function _sat(uint256 x) internal pure returns (uint128) {
        return x > type(uint128).max ? type(uint128).max : _u128(x);
    }

    function _ctx(uint8 op, uint256 v, StressInfo memory e) internal view returns (OpCtx memory c) {
        c.op = op;
        c.v = v;
        c.caller = msg.sender;
        c.anchor = e.anchorTick;
        c.calm = e.state == LockState.CALM;
        c.episode = e.stressStartedAt;
    }

    function _env(OpCtx memory c) internal view returns (Env memory env) {
        // slither-disable-next-line unused-return
        (env.sqrtP, env.tick,,) = poolManager.getSlot0(_poolId);
        env.anchor = c.anchor;
        env.calm = c.calm;
        env.episode = c.episode;
    }

    /// @dev Evaluates stress through the hook (full TWAP lookups, R-STR-7b).
    function _evalFull() internal returns (StressInfo memory) {
        return hook.evaluateStress();
    }

    /// @dev Evaluates stress and reverts unless the state is CALM (R-VLT-2).
    function _requireCalm() internal returns (StressInfo memory e) {
        e = _evalFull();
        if (e.state != LockState.CALM) {
            if (e.lockActive) {
                revert StressLockActive(e.lockedUntil);
            }
            revert NotCalm();
        }
    }

    /// @dev One `modifyLiquidity` on the hook's own position `(vaultId, slot)`. Returns the principal delta
    /// (`callerDelta - feesAccrued`, INTEGRATION note 3) and accumulates the fees into `env`.
    function _modify(
        uint256 v,
        uint256 slot,
        int24 lower,
        int24 upper,
        int256 liquidityDelta,
        Env memory env
    ) internal returns (int128 a0, int128 a1) {
        (BalanceDelta d, BalanceDelta fees) =
            _rawModify(bytes32((v << 8) | slot), lower, upper, liquidityDelta);
        // SAFETY: fees accrued are non-negative.
        env.f0 += uint128(fees.amount0());
        env.f1 += uint128(fees.amount1());
        a0 = d.amount0() - fees.amount0();
        a1 = d.amount1() - fees.amount1();
    }

    function _rawModify(bytes32 salt, int24 lower, int24 upper, int256 liquidityDelta)
        internal
        returns (BalanceDelta d, BalanceDelta fees)
    {
        return poolManager.modifyLiquidity(
            _poolKey(),
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: salt
            }),
            ""
        );
    }

    /// @dev Zero-liquidity poke of every non-empty position, collecting trading fees (R-FEE-1, R-LIQ-6).
    function _crystallize(uint256 v, Env memory env) internal {
        Position[] storage ps = _positions[v];
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].liquidity == 0) continue;
            // slither-disable-next-line unused-return
            _modify(v, i, ps[i].tickLower, ps[i].tickUpper, 0, env);
        }
    }

    /// @dev Credits collected fees: curator cut to `owed`, remainder to idle; the PoolManager credit becomes claims.
    function _flush(uint256 v, Env memory env) internal {
        uint256 f0 = env.f0;
        uint256 f1 = env.f1;
        if (f0 == 0 && f1 == 0) return;
        VaultData storage vd = _vaults[v];
        (uint256 c0, uint256 i0) = RewardMath.splitCurator(f0, vd.curatorFeeBps);
        (uint256 c1, uint256 i1) = RewardMath.splitCurator(f1, vd.curatorFeeBps);
        vd.owed0 += _u128(c0);
        vd.owed1 += _u128(c1);
        vd.idle0 += _u128(i0);
        vd.idle1 += _u128(i1);
        _toClaims(_c0(), f0);
        _toClaims(_c1(), f1);
        env.f0 = 0;
        env.f1 = 0;
    }

    /// @dev Committed depth `D_v` (anchor band) and the standby depth sample `min(D_v, live)` (ADR-025), computed by
    /// the stateless `BallastDepth` (ADR-050).
    function _measure(uint256 v, Env memory env) internal view {
        (uint256 d, uint256 l) = depthCalc.measure(
            _collateralIs0, env.anchor, env.tick, env.sqrtP, _bandTicks, _positions[v]
        );
        env.committed = _sat(d);
        env.sample = _sat(d < l ? d : l);
    }

    /// @dev Standby accrual for the interval since the last checkpoint, record counters, coverage state
    /// (R-SBY-3, R-SBY-4, R-COV-3). `env.sample` is the depth now; `dExtra` a second sample to take the minimum with
    /// (a re-range passes the depth before; others pass `type(uint128).max`).
    function _accrue(uint256 v, Env memory env, uint128 dExtra) internal {
        VaultData storage vd = _vaults[v];
        uint40 nowTs = _now();
        if (vd.pendingCommitmentAt != 0 && nowTs >= vd.pendingCommitmentAt) {
            vd.commitment = vd.pendingCommitment;
            vd.pendingCommitment = 0;
            vd.pendingCommitmentAt = 0;
            emit CommitmentChanged(v, vd.commitment, false, nowTs);
        }
        uint256 dt = RewardMath.accrualInterval(nowTs, vd.lastCheckpoint, _maxAccrualInterval);
        uint128 eligible = RewardMath.eligible(
            vd.lastDepthSample, env.sample < dExtra ? env.sample : dExtra, vd.commitment
        );
        uint256 reward;
        if (vd.breachSince == 0 && dt != 0) {
            // SAFETY: dt <= maxAccrualInterval, a uint32.
            // forge-lint: disable-next-line(unsafe-typecast)
            reward = standby.accrue(eligible, uint32(dt));
        }
        CuratorRecord storage r = _records[v];
        // SAFETY: dt <= 2^32 and an uint64 holds 2^64 seconds; the counters cannot overflow in a lifetime.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.trackedSeconds += uint64(dt);
        if (vd.coverageLostSince == 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            r.coveredSeconds += uint64(dt);
        }
        r.depthSeconds += uint256(eligible) * dt;
        if (reward != 0) _creditReward(v, reward);
        if (!env.calm && env.episode != 0 && _lastEpisode[v] != env.episode) {
            _lastEpisode[v] = env.episode;
            if (vd.breachSince == 0) ++r.stressEpisodesHeld;
        }
        vd.lastCheckpoint = nowTs;
        vd.lastDepthSample = env.sample;
        _updateCoverage(v, env);
        emit Checkpointed(v, env.sample, eligible, _u128(reward));
    }

    function _creditReward(uint256 v, uint256 reward) internal {
        VaultData storage vd = _vaults[v];
        (uint256 toCurator, uint256 toIdle) = RewardMath.splitCurator(reward, vd.curatorFeeBps);
        // The standby contract has just transferred `reward` quote claims to this contract (INV-3); only the ledger moves.
        if (_collateralIs0) {
            vd.owed1 += _u128(toCurator);
            vd.idle1 += _u128(toIdle);
        } else {
            vd.owed0 += _u128(toCurator);
            vd.idle0 += _u128(toIdle);
        }
        emit RewardCredited(v, _u128(toIdle), _u128(toCurator));
    }

    /// @dev Coverage bookkeeping. In CALM, coverage clears a breach (R-COV-3) or starts the grace clock, and the first
    /// checkpoint after `rerangeGrace` flags the breach (R-COV-1, R-COV-2; ADR-052: there is no separate flag call).
    /// Outside CALM coverage is not enforced (R-COV-4) and the clock is reset so the curator gets a full grace after
    /// calm returns.
    function _updateCoverage(uint256 v, Env memory env) internal {
        VaultData storage vd = _vaults[v];
        if (!env.calm) {
            vd.coverageLostSince = 0;
            return;
        }
        uint40 nowTs = _now();
        if (env.committed >= vd.commitment) {
            if (vd.breachSince != 0) {
                vd.breachSince = 0;
                emit BreachCleared(v);
            }
            vd.coverageLostSince = 0;
        } else if (vd.coverageLostSince == 0) {
            vd.coverageLostSince = nowTs;
            emit CoverageLost(v, nowTs + _rerangeGrace);
        } else if (vd.breachSince == 0 && nowTs >= vd.coverageLostSince + _rerangeGrace) {
            vd.breachSince = nowTs;
            ++_records[v].breachCount;
            emit BreachFlagged(v, env.committed, vd.commitment);
        }
    }

    // ─── Range validation ───

    function _validateRanges(Range[] memory ranges) internal view {
        if (ranges.length == 0 || ranges.length > MAX_POSITIONS) revert TooManyPositions();
        for (uint256 i; i < ranges.length; ++i) {
            int24 lo = ranges[i].tickLower;
            int24 hi = ranges[i].tickUpper;
            if (
                lo >= hi || lo < TickMath.MIN_TICK || hi > TickMath.MAX_TICK
                    || lo % _tickSpacing != 0 || hi % _tickSpacing != 0
            ) revert InvalidRange(lo, hi);
            for (uint256 j; j < i; ++j) {
                if (ranges[j].tickLower == lo && ranges[j].tickUpper == hi) {
                    revert DuplicateRange();
                }
            }
        }
    }

    // ─── Exit buckets (ADR-045) ───

    /// @dev Bucket width in seconds: the exit-notice span divided into `EXIT_BUCKETS`, at least one second. Rounds up,
    /// so `EXIT_BUCKETS` buckets always cover one full notice span.
    function _bucketWidth() internal view returns (uint40) {
        uint40 w = (_exitNotice + uint40(EXIT_BUCKETS) - 1) / uint40(EXIT_BUCKETS);
        return w == 0 ? 1 : w;
    }

    function _bucketAdd(uint256 v, uint40 epoch, uint128 shares) internal {
        Bucket storage b = _buckets[v][epoch % EXIT_BUCKETS];
        if (b.epoch != epoch) {
            // The slot is reused by a later epoch: its old contents are at most one bucket width from maturity and are
            // folded into the matured pool, which only ever counts them as leaving earlier (conservative).
            if (b.shares != 0) _maturedEscrow[v] += b.shares;
            b.epoch = epoch;
            b.shares = 0;
        }
        b.shares += shares;
    }

    function _bucketRemove(uint256 v, uint40 epoch, uint128 shares) internal {
        Bucket storage b = _buckets[v][epoch % EXIT_BUCKETS];
        if (b.epoch == epoch && b.shares >= shares) b.shares -= shares;
        else _maturedEscrow[v] -= shares;
    }

    // ─── Storage reads for the lens (ADR-050) ───

    /// @notice Reads `n` consecutive raw storage slots starting at `slot`. The only read-only primitive besides the
    /// public immutables; the lens decodes vault state with it (layout: docs/storage-layout.md).
    /// @dev Inline assembly: `sload` has no Solidity equivalent. It can only read this contract's own storage.
    function extsload(bytes32 slot, uint256 n) external view returns (bytes32[] memory out) {
        out = new bytes32[](n);
        assembly ("memory-safe") {
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                mstore(add(add(out, 0x20), shl(5, i)), sload(add(slot, i)))
            }
        }
    }
}
