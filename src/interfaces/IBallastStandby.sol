// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBallastErrors} from "./IBallastErrors.sol";
import {IBallastEvents} from "./IBallastEvents.sol";
import {StandbyInfo} from "../types/Types.sol";

/// @title IBallastStandby
/// @notice The sponsor-funded standby pool (ADR-046). It holds the fund as PoolManager claims and pays rewards to
/// the vaults contract; it can never move vault principal and calls nothing but the PoolManager.
interface IBallastStandby is IBallastErrors, IBallastEvents {
    /// @notice Sponsor only. Pulls `amount` of quote currency into the fund (held as PoolManager claims). Funds are
    /// not withdrawable in v1 (ADR-021).
    function fundStandby(uint128 amount) external;

    /// @notice Sponsor only. `rate <= maxStandbyRate`. Unit: quote raw per collateral raw per second, scaled by 1e18.
    function setStandbyRate(uint128 rate) external;

    /// @notice Vaults only. Computes `floor(eligibleDepth * dt * rate / RATE_SCALE)` capped by the fund, debits the
    /// fund and transfers that many quote claims to the vaults contract. Returns the amount transferred.
    function accrue(uint128 eligibleDepth, uint32 dt) external returns (uint256 reward);

    /// @notice Fund balance, rate and total credited.
    function standbyInfo() external view returns (StandbyInfo memory);
}
