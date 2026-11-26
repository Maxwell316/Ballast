// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBallastDepthOracle} from "./IBallastDepthOracle.sol";
import {PositionView, TicketView, VaultView} from "../types/Types.sol";

/// @title IBallastLens
/// @notice Read-only periphery (ADR-048, ADR-050). It decodes the vaults' storage through `extsload` and runs the
/// same `DepthMath`/`BandMath` code as the vaults' depth calculator. Loops iterate vault positions and are bounded by
/// MAX_VAULTS x MAX_POSITIONS (R-VIEW-4).
interface IBallastLens is IBallastDepthOracle {
    /// @notice Anchor-band depth of one vault (`D_v`, not capped by the commitment).
    function vaultDepth(uint256 vaultId) external view returns (uint256 committed);

    /// @notice Absorbable collateral from spot over `impactBps`, all vault positions, no exit netting.
    function poolAbsorbable(uint16 impactBps) external view returns (uint256 collateralAmount);

    /// @notice Open ticket shares of a vault whose effective exit `max(maturity, earliestRelease)` is within
    /// `horizon` seconds. Never below the exact figure (ADR-047, ADR-048).
    function exitingShares(uint256 vaultId, uint32 horizon) external view returns (uint256);

    function vaultCount() external view returns (uint256);
    function vault(uint256 vaultId) external view returns (VaultView memory);
    function positionsOf(uint256 vaultId) external view returns (PositionView[] memory);
    function ticket(uint256 ticketId) external view returns (TicketView memory);

    /// @notice Estimate of what `deposit(vaultId, shares, ...)` would cost now; the PoolManager's rounding is
    /// authoritative at execution time.
    function previewDeposit(uint256 vaultId, uint128 shares)
        external
        view
        returns (uint128 amount0, uint128 amount1);

    /// @notice Estimate of what redeeming `shares` of a vault would return now.
    function previewRedeem(uint256 vaultId, uint128 shares)
        external
        view
        returns (uint128 amount0, uint128 amount1);
}
