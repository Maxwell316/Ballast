// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BallastShares} from "../BallastShares.sol";
import {IBallastHook} from "../interfaces/IBallastHook.sol";
import {IBallastDepthOracle} from "../interfaces/IBallastDepthOracle.sol";
import {IBallastLens} from "../interfaces/IBallastLens.sol";
import {IBallastVaults} from "../interfaces/IBallastVaults.sol";
import {BandMath} from "../libraries/BandMath.sol";
import {DepthMath} from "../libraries/DepthMath.sol";
import {VaultMath} from "../libraries/VaultMath.sol";
import {VaultsLayout as L} from "../libraries/VaultsLayout.sol";
import {EXIT_BUCKETS} from "../types/Constants.sol";
import {
    Config,
    CuratorRecord,
    LockState,
    Position,
    PositionView,
    StressInfo,
    TicketView,
    VaultView
} from "../types/Types.sol";

/// @dev `BaseHook.poolManager()`, which `IBallastHook` does not declare.
interface IPoolManagerGetter {
    function poolManager() external view returns (address);
}

/// @title BallastLens
/// @notice Read-only depth and state views for risk consumers (ADR-048, ADR-050). It holds no funds and no state of
/// its own beyond immutables derived from the hook's configuration.
/// @dev Consumers size supply caps from `liveDepth` (ADR-027); `committedDepth` is for coverage and rewards.
contract BallastLens is IBallastLens {
    using StateLibrary for IPoolManager;

    IBallastHook public immutable hook;
    IBallastVaults public immutable vaults;
    BallastShares public immutable shareToken;
    IPoolManager public immutable poolManager;
    bool private immutable _collateralIs0;
    uint24 private immutable _bandTicks;
    uint32 private immutable _exitNotice;

    /// @param hook_ The deployed hook. Its vaults are read from `hook_.vaults()`.
    /// @param shareToken_ The vaults' share token (`BallastVaults.shareToken()`).
    constructor(IBallastHook hook_, BallastShares shareToken_) {
        hook = hook_;
        vaults = IBallastVaults(hook_.vaults());
        shareToken = shareToken_;
        Config memory c = hook_.config();
        poolManager = IPoolManager(IPoolManagerGetter(address(hook_)).poolManager());
        // Derived from the immutable config, not from the hook's binding state, so a lens built before the pool is
        // initialised cannot read the wrong liquidation direction.
        _collateralIs0 = Currency.unwrap(c.collateral) < Currency.unwrap(c.quote);
        _bandTicks = BandMath.bpsToTicksDown(c.bandBps);
        _exitNotice = c.exitNotice;
    }

    // ─── Decoding helpers ───

    function _slots(bytes32 slot, uint256 n) internal view returns (bytes32[] memory) {
        return vaults.extsload(slot, n);
    }

    function _word(bytes32 slot) internal view returns (bytes32) {
        return vaults.extsload(slot, 1)[0];
    }

    /// @dev Positions of a vault, one storage slot each: `{int24 lower @0, int24 upper @3, uint128 liquidity @6}`.
    function _positions(uint256 v) internal view returns (Position[] memory ps) {
        uint256 n = uint256(_word(L.positionsLengthSlot(v)));
        bytes32[] memory w = _slots(L.positionsDataSlot(v), n);
        ps = new Position[](n);
        for (uint256 i; i < n; ++i) {
            // SAFETY: the fields were stored as int24/int24/uint128 and are read back at the same widths.
            // forge-lint: disable-start(unsafe-typecast)
            ps[i] = Position(
                int24(L.sfield(w[i], 0, 3)),
                int24(L.sfield(w[i], 3, 3)),
                uint128(L.field(w[i], 6, 16))
            );
            // forge-lint: disable-end(unsafe-typecast)
        }
    }

    /// @dev `lastCheckpoint @0 (5), breachSince @5 (5)` of slot 4; `commitment` is slot 1 low half.
    function _vaultWords(uint256 v) internal view returns (bytes32[] memory) {
        return _slots(L.vaultSlot(v), L.VAULT_SLOTS);
    }

    function _count() internal view returns (uint256) {
        return uint256(_word(bytes32(L.SLOT_VAULT_COUNT)));
    }

    function _supply(uint256 v) internal view returns (uint256) {
        return shareToken.totalSupply(v);
    }

    function _anchor() internal view returns (int24) {
        return hook.stressInfo().anchorTick;
    }

    // ─── State views ───

    /// @inheritdoc IBallastLens
    function vaultCount() external view returns (uint256) {
        return _count();
    }

    /// @inheritdoc IBallastLens
    function vault(uint256 vaultId) external view returns (VaultView memory out) {
        bytes32[] memory w = _vaultWords(vaultId);
        // SAFETY: each field is read back at the width it was stored with (layout pinned by LensLayout.t.sol).
        // forge-lint: disable-start(unsafe-typecast)
        out = VaultView({
            curator: address(uint160(L.field(w[0], 0, 20))),
            curatorFeeBps: uint16(L.field(w[0], 20, 2)),
            commitment: uint128(L.field(w[1], 0, 16)),
            pendingCommitment: uint128(L.field(w[1], 16, 16)),
            pendingCommitmentAt: uint40(L.field(w[0], 23, 5)),
            totalShares: uint128(_supply(vaultId)),
            idle0: uint128(L.field(w[2], 0, 16)),
            idle1: uint128(L.field(w[2], 16, 16)),
            curatorOwed0: uint128(L.field(w[3], 0, 16)),
            curatorOwed1: uint128(L.field(w[3], 16, 16)),
            lastCheckpoint: uint40(L.field(w[4], 0, 5)),
            breachSince: uint40(L.field(w[4], 5, 5)),
            positionCount: uint8(L.field(w[0], 22, 1))
        });
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @inheritdoc IBallastLens
    function positionsOf(uint256 vaultId) external view returns (PositionView[] memory out) {
        Position[] memory ps = _positions(vaultId);
        out = new PositionView[](ps.length);
        for (uint256 i; i < ps.length; ++i) {
            out[i] = PositionView(ps[i].tickLower, ps[i].tickUpper, ps[i].liquidity);
        }
    }

    /// @inheritdoc IBallastLens
    function ticket(uint256 ticketId) external view returns (TicketView memory) {
        bytes32[] memory w = _slots(L.ticketSlot(ticketId), L.TICKET_SLOTS);
        // SAFETY: fields read back at stored widths.
        // forge-lint: disable-start(unsafe-typecast)
        return TicketView(
            L.field(w[0], 25, 2),
            address(uint160(L.field(w[0], 0, 20))),
            uint128(L.field(w[1], 0, 16)),
            uint40(L.field(w[0], 20, 5))
        );
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @inheritdoc IBallastDepthOracle
    function vaultRecord(uint256 vaultId) external view returns (CuratorRecord memory r) {
        bytes32[] memory w = _slots(L.recordSlot(vaultId), L.RECORD_SLOTS);
        // SAFETY: fields read back at stored widths.
        // forge-lint: disable-start(unsafe-typecast)
        r = CuratorRecord({
            coveredSeconds: uint64(L.field(w[0], 0, 8)),
            trackedSeconds: uint64(L.field(w[0], 8, 8)),
            rerangeCount: uint32(L.field(w[0], 16, 4)),
            breachCount: uint32(L.field(w[0], 20, 4)),
            stressEpisodesHeld: uint32(L.field(w[0], 24, 4)),
            depthSeconds: uint256(w[1])
        });
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @inheritdoc IBallastDepthOracle
    function lockState() external view returns (LockState state, uint40 lockedUntil) {
        return hook.lockState();
    }

    // ─── Depth views ───

    /// @dev Anchor-band absorbable collateral of `ps`, summed (rounded down).
    function _committed(Position[] memory ps, int24 anchor) internal view returns (uint256 d) {
        (int24 near, int24 far) = BandMath.bandEdges(anchor, _collateralIs0, _bandTicks);
        for (uint256 i; i < ps.length; ++i) {
            d += DepthMath.absorbable(
                _collateralIs0, ps[i].tickLower, ps[i].tickUpper, ps[i].liquidity, near, far
            );
        }
    }

    /// @dev Absorbable collateral of `ps` from spot over `bandTicks_`, summed (rounded down).
    function _live(Position[] memory ps, uint160 sqrtP, int24 tick, uint24 bandTicks_)
        internal
        view
        returns (uint256 l)
    {
        // slither-disable-next-line unused-return
        (, int24 far) = BandMath.bandEdges(tick, _collateralIs0, bandTicks_);
        for (uint256 i; i < ps.length; ++i) {
            l += DepthMath.liveAbsorbable(
                _collateralIs0, ps[i].tickLower, ps[i].tickUpper, ps[i].liquidity, sqrtP, far
            );
        }
    }

    /// @inheritdoc IBallastLens
    function vaultDepth(uint256 vaultId) external view returns (uint256) {
        return _committed(_positions(vaultId), _anchor());
    }

    /// @inheritdoc IBallastDepthOracle
    function vaultStatus(uint256 vaultId)
        external
        view
        returns (uint128 depth, uint128 commitment, bool inBreach)
    {
        bytes32[] memory w = _vaultWords(vaultId);
        // SAFETY: depth is bounded by the pool's collateral supply; saturating cast is never needed in practice but
        // is applied for the 128-bit return type.
        depth = _sat(_committed(_positions(vaultId), _anchor()));
        // forge-lint: disable-next-line(unsafe-typecast)
        commitment = uint128(L.field(w[1], 0, 16));
        inBreach = L.field(w[4], 5, 5) != 0;
    }

    /// @inheritdoc IBallastDepthOracle
    /// @dev Sum over seeded vaults not in breach of `min(D_v, commitment)` (R-VIEW-1).
    function committedDepth() external view returns (uint256 total) {
        int24 anchor = _anchor();
        uint256 n = _count();
        for (uint256 v = 1; v <= n; ++v) {
            if (_supply(v) == 0) continue;
            bytes32[] memory w = _vaultWords(v);
            if (L.field(w[4], 5, 5) != 0) continue;
            uint256 d = _committed(_positions(v), anchor);
            uint256 k = L.field(w[1], 0, 16);
            total += d < k ? d : k;
        }
    }

    /// @inheritdoc IBallastLens
    function poolAbsorbable(uint16 impactBps) external view returns (uint256 total) {
        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(PoolId.wrap(_poolId()));
        uint24 bt = BandMath.bpsToTicksDown(impactBps);
        uint256 n = _count();
        for (uint256 v = 1; v <= n; ++v) {
            total += _live(_positions(v), sqrtP, tick, bt);
        }
    }

    /// @inheritdoc IBallastDepthOracle
    /// @dev Per vault: live depth from spot times `(supply - exiting) / supply`, rounded down (ADR-047, R-VIEW-2).
    function liveDepth(uint16 impactBps, uint32 horizon) external view returns (uint256 total) {
        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(PoolId.wrap(_poolId()));
        uint24 bt = BandMath.bpsToTicksDown(impactBps);
        uint256 limit = uint256(block.timestamp) + horizon;
        bool released = hook.stressInfo().earliestRelease <= limit;
        uint256 n = _count();
        for (uint256 v = 1; v <= n; ++v) {
            uint256 s = _supply(v);
            if (s == 0) continue;
            uint256 l = _live(_positions(v), sqrtP, tick, bt);
            uint256 e = released ? _exiting(v, limit) : 0;
            total += e >= s ? 0 : FixedPointMathLib.fullMulDiv(l, s - e, s);
        }
    }

    function _poolId() internal view returns (bytes32 id) {
        return PoolId.unwrap(hook.poolId());
    }

    // ─── Exit netting (ADR-047, ADR-048) ───

    function _bucketWidth() internal view returns (uint256) {
        uint256 w = (uint256(_exitNotice) + EXIT_BUCKETS - 1) / EXIT_BUCKETS;
        return w == 0 ? 1 : w;
    }

    /// @dev Matured pool plus every bucket whose epoch start is within `limit`. Bucket starts round maturity down, so
    /// the count is never below the exact figure.
    function _exiting(uint256 v, uint256 limit) internal view returns (uint256 shares) {
        shares = L.field(_word(L.maturedSlot(v)), 0, 16);
        bytes32[] memory b = _slots(L.bucketsSlot(v), EXIT_BUCKETS);
        uint256 w = _bucketWidth();
        for (uint256 i; i < EXIT_BUCKETS; ++i) {
            uint256 s = L.field(b[i], 5, 16);
            if (s != 0 && L.field(b[i], 0, 5) * w <= limit) shares += s;
        }
    }

    /// @inheritdoc IBallastLens
    function exitingShares(uint256 vaultId, uint32 horizon) external view returns (uint256) {
        uint256 limit = uint256(block.timestamp) + horizon;
        if (hook.stressInfo().earliestRelease > limit) return 0;
        return _exiting(vaultId, limit);
    }

    // ─── Previews ───

    /// @inheritdoc IBallastLens
    function previewDeposit(uint256 vaultId, uint128 shares)
        external
        view
        returns (uint128 a0, uint128 a1)
    {
        return _preview(vaultId, shares, true);
    }

    /// @inheritdoc IBallastLens
    function previewRedeem(uint256 vaultId, uint128 shares)
        external
        view
        returns (uint128 a0, uint128 a1)
    {
        return _preview(vaultId, shares, false);
    }

    function _preview(uint256 vaultId, uint128 shares, bool add)
        internal
        view
        returns (uint128, uint128)
    {
        uint256 supply = _supply(vaultId);
        if (supply == 0) return (0, 0);
        (uint160 sqrtP,,,) = poolManager.getSlot0(PoolId.wrap(_poolId()));
        Position[] memory ps = _positions(vaultId);
        uint256 t0;
        uint256 t1;
        for (uint256 i; i < ps.length; ++i) {
            uint256 dl = add
                ? VaultMath.ceilShare(ps[i].liquidity, shares, supply)
                : VaultMath.floorShare(ps[i].liquidity, shares, supply);
            (uint256 x0, uint256 x1) = _amounts(ps[i], dl, sqrtP, add);
            t0 += x0;
            t1 += x1;
        }
        bytes32 idle = _slots(L.vaultSlot(vaultId), 3)[2];
        uint256 i0 = L.field(idle, 0, 16);
        uint256 i1 = L.field(idle, 16, 16);
        t0 += add
            ? VaultMath.ceilShare(i0, shares, supply)
            : VaultMath.floorShare(i0, shares, supply);
        t1 += add
            ? VaultMath.ceilShare(i1, shares, supply)
            : VaultMath.floorShare(i1, shares, supply);
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint128(t0), uint128(t1));
    }

    /// @dev Token amounts of `dl` liquidity of `p` at `sqrtP`, rounded as the PoolManager does (adds up, removes down).
    function _amounts(Position memory p, uint256 dl, uint160 sqrtP, bool roundUp)
        internal
        pure
        returns (uint256 a0, uint256 a1)
    {
        // SAFETY: dl <= position liquidity <= 2^128.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 liq = uint128(dl);
        uint160 lo = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(p.tickUpper);
        if (sqrtP <= lo) {
            a0 = SqrtPriceMath.getAmount0Delta(lo, hi, liq, roundUp);
        } else if (sqrtP < hi) {
            a0 = SqrtPriceMath.getAmount0Delta(sqrtP, hi, liq, roundUp);
            a1 = SqrtPriceMath.getAmount1Delta(lo, sqrtP, liq, roundUp);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(lo, hi, liq, roundUp);
        }
    }

    function _sat(uint256 x) internal pure returns (uint128) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return x > type(uint128).max ? type(uint128).max : uint128(x);
    }
}
