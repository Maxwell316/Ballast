// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BallastHook} from "../src/BallastHook.sol";
import {BallastVaults} from "../src/BallastVaults.sol";
import {BallastShares} from "../src/BallastShares.sol";
import {BallastStandby} from "../src/BallastStandby.sol";
import {BallastLens} from "../src/periphery/BallastLens.sol";
import {HookPermissions} from "../src/libraries/HookPermissions.sol";
import {Config} from "../src/types/Types.sol";

/// @title VerifyBinding
/// @notice Reads a deployed Ballast pool and asserts every binding in both directions (ADR-050, T20). A deployment is
/// valid only if this script passes. Reads `HOOK` (and optionally `LENS`) from the environment; everything else is
/// derived from the hook. Reverts with a descriptive message on the first violated binding. Read-only: no broadcast.
/// @dev Usage: `HOOK=0x... [LENS=0x...] forge script script/VerifyBinding.s.sol --rpc-url <url>`.
contract VerifyBinding is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function run() external view {
        BallastHook hook = BallastHook(vm.envAddress("HOOK"));
        verify(hook, vm.envOr("LENS", address(0)));
        console2.log("binding verified for hook", address(hook));
    }

    /// @notice Asserts the full binding graph of `hook`; `lens` is checked only if non-zero.
    function verify(BallastHook hook, address lens) public view {
        require(address(hook).code.length > 0, "hook has no code");
        BallastVaults vaults = BallastVaults(hook.vaults());
        require(address(vaults).code.length > 0, "vaults have no code");
        require(address(vaults.hook()) == address(hook), "vaults.hook != hook");

        BallastShares shares = vaults.shareToken();
        require(address(shares).code.length > 0, "shares have no code");
        require(shares.vaults() == address(vaults), "shares.vaults != vaults");

        BallastStandby standby = BallastStandby(address(vaults.standby()));
        require(address(standby).code.length > 0, "standby has no code");
        require(standby.vaults() == address(vaults), "standby.vaults != vaults");
        require(address(vaults.depthCalc()).code.length > 0, "depthCalc has no code");

        Config memory cfg = hook.config();
        require(vaults.configHash() == keccak256(abi.encode(cfg)), "config hash mismatch");
        require(
            address(vaults.poolManager()) == address(hook.poolManager()), "poolManager mismatch"
        );
        require(
            address(standby.poolManager()) == address(hook.poolManager()), "standby pm mismatch"
        );

        require(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK
                == HookPermissions.flags(hook.getHookPermissions()),
            "hook address flags differ from getHookPermissions()"
        );

        IPoolManager pm = IPoolManager(address(hook.poolManager()));
        PoolKey memory key = PoolKey(
            hook.collateralIsCurrency0() ? cfg.collateral : cfg.quote,
            hook.collateralIsCurrency0() ? cfg.quote : cfg.collateral,
            cfg.fee,
            cfg.tickSpacing,
            IHooks(address(hook))
        );
        require(
            PoolId.unwrap(key.toId()) == PoolId.unwrap(hook.poolId()), "pool id differs from hook"
        );
        (uint160 sqrtP,,,) = pm.getSlot0(key.toId());
        require(sqrtP != 0, "pool not initialised");

        if (lens != address(0)) {
            require(address(BallastLens(lens).hook()) == address(hook), "lens.hook != hook");
            require(address(BallastLens(lens).vaults()) == address(vaults), "lens.vaults mismatch");
            require(
                address(BallastLens(lens).shareToken()) == address(shares), "lens.shares mismatch"
            );
        }
    }
}
