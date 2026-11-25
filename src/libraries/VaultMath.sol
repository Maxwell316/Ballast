// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title VaultMath
/// @notice Proportional share arithmetic with explicit rounding (docs/MATH.md §6). No price, NAV or
/// `balanceOf` enters: an amount of liquidity or idle balance is scaled by `shares / supply`.
/// @dev `ceilShare` is used when an actor pays (deposit: liquidity and idle slices), `floorShare` when an actor
/// receives (redeem). Both round against the actor, so the vault never loses to rounding (INV-5, T9).
library VaultMath {
    /// @notice `supply` was zero. A seeded vault always has `supply >= MINIMUM_SHARES`.
    error ZeroSupply();

    /// @notice `ceil(amount * shares / supply)`: what an entering actor owes for `shares` of a pool of `amount`.
    /// @dev Rounds up. The 512-bit intermediate cannot overflow; the call reverts only if the result exceeds
    /// 2^256 - 1. Reverts `ZeroSupply` if `supply == 0`.
    /// @param amount A vault total (position liquidity or an idle balance).
    /// @param shares Shares being minted.
    /// @param supply Total share supply before the mint, including escrow and the burned minimum.
    /// @return The amount owed, rounded up.
    /// @custom:requirement R-VLT-3
    /// @custom:invariant INV-5
    function ceilShare(uint256 amount, uint256 shares, uint256 supply)
        internal
        pure
        returns (uint256)
    {
        if (supply == 0) revert ZeroSupply();
        return FixedPointMathLib.fullMulDivUp(amount, shares, supply);
    }

    /// @notice `floor(amount * shares / supply)`: what a leaving actor receives for `shares` of a pool of `amount`.
    /// @dev Rounds down. Reverts `ZeroSupply` if `supply == 0`.
    /// @param amount A vault total (position liquidity or an idle balance).
    /// @param shares Shares being burned.
    /// @param supply Total share supply before the burn, including escrow and the burned minimum.
    /// @return The amount received, rounded down.
    /// @custom:requirement R-VLT-8
    /// @custom:invariant INV-5
    function floorShare(uint256 amount, uint256 shares, uint256 supply)
        internal
        pure
        returns (uint256)
    {
        if (supply == 0) revert ZeroSupply();
        return FixedPointMathLib.fullMulDiv(amount, shares, supply);
    }
}
