// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title HookPermissions
/// @notice The single definition of Ballast's hook permissions (D-5): exactly five flags, no return-delta flags.
/// @dev `BallastHook.getHookPermissions()` returns `permissions()`, and the deployment script derives the address-mining
/// flags from the same function, so the contract and the script cannot drift apart. `flags()` converts the struct to
/// the address bit mask using the `Hooks.*_FLAG` constants (never hard-coded bits, CLAUDE.md §6.2).
library HookPermissions {
    /// @notice Ballast's permissions.
    function permissions() internal pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true; // bind the pool, validate the key (R-POOL-1..3, R-POOL-6)
        p.afterInitialize = true; // seed the oracle (R-POOL-4)
        p.beforeAddLiquidity = true; // revert for external callers (G-1)
        p.beforeRemoveLiquidity = true; // revert for external callers (G-1)
        p.beforeSwap = true; // oracle write, stress evaluation, D-9 guard
    }

    /// @notice The address bit mask of `p`.
    function flags(Hooks.Permissions memory p) internal pure returns (uint160 m) {
        if (p.beforeInitialize) m |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (p.afterInitialize) m |= Hooks.AFTER_INITIALIZE_FLAG;
        if (p.beforeAddLiquidity) m |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (p.afterAddLiquidity) m |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (p.beforeRemoveLiquidity) m |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (p.afterRemoveLiquidity) m |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (p.beforeSwap) m |= Hooks.BEFORE_SWAP_FLAG;
        if (p.afterSwap) m |= Hooks.AFTER_SWAP_FLAG;
        if (p.beforeDonate) m |= Hooks.BEFORE_DONATE_FLAG;
        if (p.afterDonate) m |= Hooks.AFTER_DONATE_FLAG;
        if (p.beforeSwapReturnDelta) m |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterSwapReturnDelta) m |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterAddLiquidityReturnDelta) m |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (p.afterRemoveLiquidityReturnDelta) {
            m |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
        }
    }
}
