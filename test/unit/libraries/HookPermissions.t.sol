// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookPermissions} from "../../../src/libraries/HookPermissions.sol";

/// @notice `HookPermissions` is the single source of Ballast's permission set and of the address-mining mask (D-5,
/// T15). The mask conversion is checked flag by flag against the `Hooks.*_FLAG` constants.
/// @custom:requirement R-LIQ-4
contract HookPermissionsTest is Test {
    function test_Permissions_AreExactlyTheFive() public pure {
        Hooks.Permissions memory p = HookPermissions.permissions();
        assertTrue(
            p.beforeInitialize && p.afterInitialize && p.beforeAddLiquidity
                && p.beforeRemoveLiquidity && p.beforeSwap
        );
        assertFalse(p.afterAddLiquidity || p.afterRemoveLiquidity || p.afterSwap);
        assertFalse(p.beforeDonate || p.afterDonate);
        assertFalse(
            p.beforeSwapReturnDelta || p.afterSwapReturnDelta || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
    }

    function test_Flags_OfBallastPermissions_EqualTheFiveFlagConstants() public pure {
        uint160 expected = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG;
        assertEq(HookPermissions.flags(HookPermissions.permissions()), expected);
    }

    function test_Flags_AllPermissions_EqualAllHookMask() public pure {
        Hooks.Permissions memory p = Hooks.Permissions(
            true, true, true, true, true, true, true, true, true, true, true, true, true, true
        );
        assertEq(HookPermissions.flags(p), Hooks.ALL_HOOK_MASK);
        assertEq(
            HookPermissions.flags(
                Hooks.Permissions(
                    false,
                    false,
                    false,
                    false,
                    false,
                    false,
                    false,
                    false,
                    false,
                    false,
                    false,
                    false,
                    false,
                    false
                )
            ),
            0
        );
    }

    /// @notice Each permission maps to exactly its own distinct flag bit.
    function testFuzz_Flags_EachPermissionMapsToItsOwnBit(uint16 bits) public pure {
        bool[14] memory b;
        for (uint256 i; i < 14; ++i) {
            b[i] = (bits >> i) & 1 == 1;
        }
        Hooks.Permissions memory p = Hooks.Permissions(
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13]
        );
        uint160[14] memory f = [
            Hooks.BEFORE_INITIALIZE_FLAG,
            Hooks.AFTER_INITIALIZE_FLAG,
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG,
            Hooks.AFTER_ADD_LIQUIDITY_FLAG,
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG,
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG,
            Hooks.BEFORE_SWAP_FLAG,
            Hooks.AFTER_SWAP_FLAG,
            Hooks.BEFORE_DONATE_FLAG,
            Hooks.AFTER_DONATE_FLAG,
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG,
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG,
            Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        ];
        uint160 expected;
        for (uint256 i; i < 14; ++i) {
            if (b[i]) expected |= f[i];
        }
        assertEq(HookPermissions.flags(p), expected);
    }
}
