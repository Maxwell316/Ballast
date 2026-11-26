// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBallastPool} from "./IBallastPool.sol";
import {StressInfo} from "../types/Types.sol";

/// @title IBallastHook
/// @notice Hook-side surface used by the vaults (ADR-045). The hook calls nothing on the vaults after construction.
interface IBallastHook is IBallastPool {
    /// @notice The `BallastVaults` contract bound immutably at deployment; the only address admitted by the liquidity gate (G-1).
    function vaults() external view returns (address);

    /// @notice Vaults only. Reverts if the transaction already swapped, then sets the `VAULT_OP` flag (R-TX-2).
    function enterVaultOp() external;

    /// @notice Permissionless. Advances the oracle, evaluates the stress machine with full TWAP lookups and returns
    /// the result (the logic of `pokeStress`, R-STR-7).
    function evaluateStress() external returns (StressInfo memory);
}
