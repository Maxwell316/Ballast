// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Maximum number of vaults in the pool. Bounds every loop over vaults.
uint256 constant MAX_VAULTS = 16;
/// @dev Maximum number of positions per vault. Bounds every loop over positions.
uint256 constant MAX_POSITIONS = 8;
/// @dev Shares permanently burned on a vault's first deposit (inflation-attack floor).
uint128 constant MINIMUM_SHARES = 1e3;
/// @dev Shares minted by a vault's `seed`.
uint128 constant INITIAL_SHARES = 1e18;
/// @dev Fixed-point scale of the standby rate: quote raw units per collateral raw unit per second.
uint256 constant RATE_SCALE = 1e18;
/// @dev Basis-point denominator.
uint256 constant BPS_DENOMINATOR = 10_000;
