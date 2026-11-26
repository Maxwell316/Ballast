// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IBallastErrors} from "./IBallastErrors.sol";
import {IBallastEvents} from "./IBallastEvents.sol";
import {Config, LockState, StressInfo} from "../types/Types.sol";

/// @title IBallastPool
/// @notice Pool-binding, oracle and stress surface of the hook (M2). `IBallastHook` extends it.
/// @dev Views never write state: stress views apply the pure `StressMachine.next` to current inputs (R-STR-7).
interface IBallastPool is IBallastErrors, IBallastEvents {
    /// @notice The immutable configuration this hook was deployed with.
    function config() external view returns (Config memory);

    /// @notice The bound pool id; zero until `beforeInitialize` binds the pool (R-POOL-1).
    function poolId() external view returns (PoolId);

    /// @notice Whether the collateral is currency0 of the bound pool (R-POOL-3).
    function collateralIsCurrency0() external view returns (bool);

    /// @notice Time-weighted average tick over `window` seconds; `warm` is false if history is shorter (R-ORC-2/4).
    /// @param window Window in seconds, non-zero.
    function twapTick(uint32 window) external view returns (int24 tick, bool warm);

    /// @notice Snapshot of the stress machine as it would be if evaluated now (pure preview, R-STR-7).
    function stressInfo() external view returns (StressInfo memory);

    /// @notice The previewed lock state and the time the lock ends (0 if inactive). Same preview as `stressInfo`.
    function lockState() external view returns (LockState state, uint40 lockedUntil);

    /// @notice Permissionless. Advances the oracle accumulator and evaluates the stress machine now (R-STR-7c).
    /// @dev Never reverts for a bound pool except through the oracle domain limits in docs/MATH.md §4.
    function pokeStress() external;
}
