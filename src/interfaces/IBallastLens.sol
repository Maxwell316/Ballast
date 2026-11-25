// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBallastDepthOracle} from "./IBallastDepthOracle.sol";

/// @title IBallastLens
/// @notice Read-only periphery. Loops iterate vault positions and are bounded by MAX_VAULTS x MAX_POSITIONS.
interface IBallastLens is IBallastDepthOracle {
    /// @notice Anchor-band depth of one vault.
    function vaultDepth(uint256 vaultId) external view returns (uint256 committed);

    /// @notice Absorbable collateral from spot over `impactBps`, all vault positions, no exit netting.
    function poolAbsorbable(uint16 impactBps) external view returns (uint256 collateralAmount);
}
