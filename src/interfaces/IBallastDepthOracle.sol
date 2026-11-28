// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CuratorRecord, LockState} from "../types/Types.sol";

/// @title IBallastDepthOracle
/// @notice Depth views for lending risk consumers.
/// @dev Consumer guidance (ADR-027): size supply caps from `liveDepth`, with `impactBps` chosen to match the
/// liquidation-penalty price impact and `horizon` chosen to cover the consumer's required depth-availability window.
/// `committedDepth` is anchor-based, does not net exits and does not measure from spot; it exists for coverage and
/// reward accounting, not lender cap sizing. `SupplyCapAdvisor` is illustrative; the consumer chooses its multiplier.
interface IBallastDepthOracle {
    /// @notice Collateral absorbable inside the anchor band by compliant vaults, `min(D_v, K_v)` summed.
    /// @return collateralAmount Collateral raw units, rounded down.
    function committedDepth() external view returns (uint256 collateralAmount);

    /// @notice Collateral absorbable from current spot over `impactBps` of price impact, net of exits
    /// maturing within `horizon` seconds.
    /// @param impactBps Price impact in basis points.
    /// @param horizon Seconds the consumer requires depth to remain available; maturing exits inside this window
    /// are netted unless the stress lock prevents them from leaving.
    /// @return collateralAmount Collateral raw units, rounded down, net of fees.
    function liveDepth(uint16 impactBps, uint32 horizon)
        external
        view
        returns (uint256 collateralAmount);

    /// @notice Current lock state and, if the lock is active, when it ends.
    function lockState() external view returns (LockState state, uint40 lockedUntil);

    /// @notice Exact on-chain counters of a vault.
    function vaultRecord(uint256 vaultId) external view returns (CuratorRecord memory);

    /// @notice Committed depth, commitment and breach flag of one vault.
    function vaultStatus(uint256 vaultId)
        external
        view
        returns (uint128 depth, uint128 commitment, bool inBreach);
}
