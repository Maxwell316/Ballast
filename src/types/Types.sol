// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice A tick range for one position. Both ticks must be multiples of the pool's tick spacing.
struct Range {
    int24 tickLower;
    int24 tickUpper;
}

/// @notice Stress machine states. CALM is the only state in which exits and re-ranges are unrestricted.
enum LockState {
    CALM,
    STRESS,
    RECOVERING
}

/// @notice Immutable hook configuration, validated by `ConfigLib.validate` in the constructor.
/// @dev Durations are seconds (`uint32`), basis points are 1e-4 (`uint16`), fees are pips 1e-6 (`uint24`).
struct Config {
    Currency collateral; // the asset being liquidated (sold into the pool)
    Currency quote; // the asset liquidators receive
    address sponsor; // funds the standby pool and sets the rate within bounds
    address initializer; // the only address allowed to initialize the pool (ADR-014)
    uint24 fee; // static LP fee the pool must use, in pips
    int24 tickSpacing; // tick spacing the pool must use
    uint16 bandBps; // X: depth band, price impact below the anchor
    uint16 stressEnterBps; // theta: short TWAP deviation that enters stress
    uint16 stressExitBps; // below stressEnterBps (hysteresis)
    uint32 anchorWindow; // seconds, TWAP window for the anchor price
    uint32 shortWindow; // seconds, TWAP window for the stress test
    uint32 calmDuration; // seconds below the exit threshold before CALM
    uint32 maxStressLock; // hard cap on how long a stress episode can lock exits
    uint32 exitNotice; // seconds between requestRedeem and claim
    uint32 rerangeGrace; // seconds to restore coverage after anchor drift
    uint32 maxAccrualInterval; // cap on a single accrual interval
    uint16 maxCuratorFeeBps; // upper bound for a vault's curator fee
    uint32 observationInterval; // minimum seconds between oracle snapshots
    uint16 observationCardinality; // ring-buffer size, fixed at construction
    uint128 maxStandbyRate; // upper bound for the sponsor-set rate
}

/// @notice Read-only view of a vault.
struct VaultView {
    address curator;
    uint16 curatorFeeBps;
    uint128 commitment;
    uint128 pendingCommitment;
    uint40 pendingCommitmentAt;
    uint128 totalShares; // includes escrowed shares and the burned minimum
    uint128 idle0;
    uint128 idle1;
    uint128 curatorOwed0;
    uint128 curatorOwed1;
    uint40 lastCheckpoint;
    uint40 breachSince; // 0 when covered
    uint8 positionCount;
}

/// @notice Stored vault position. `liquidity` is zero for a slot that holds nothing; such a slot is never poked.
struct Position {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}

/// @notice Read-only view of one vault position.
struct PositionView {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}

/// @notice Read-only view of a redeem ticket. A ticket carries no receiver (ADR-016).
struct TicketView {
    uint256 vaultId;
    address owner;
    uint128 shares;
    uint40 maturity;
}

/// @notice Exact on-chain counters describing a curator's vault. No off-chain inputs.
struct CuratorRecord {
    uint64 coveredSeconds;
    uint64 trackedSeconds;
    uint32 rerangeCount;
    uint32 breachCount;
    uint32 stressEpisodesHeld;
    uint256 depthSeconds;
}

/// @notice Read-only snapshot of the stress machine.
struct StressInfo {
    LockState state;
    bool oracleWarm;
    bool lockActive;
    uint40 stressStartedAt;
    uint40 lockedUntil; // 0 if the lock is inactive
    int24 anchorTick;
    int24 shortTick;
    uint40 earliestUnlock; // earliest time exits could be allowed again (now when the lock is inactive)
}

/// @notice Read-only snapshot of the standby fund.
struct StandbyInfo {
    uint128 fundBalance;
    uint128 rate;
    uint256 totalCredited;
}
