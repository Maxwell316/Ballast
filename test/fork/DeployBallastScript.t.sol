// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {DeployBallast} from "../../script/DeployBallast.s.sol";
import {VerifyBinding} from "../../script/VerifyBinding.s.sol";
import {BallastVaults} from "../../src/BallastVaults.sol";
import {HookPermissions} from "../../src/libraries/HookPermissions.sol";
import {BallastHook} from "../../src/BallastHook.sol";
import {Config, LockState} from "../../src/types/Types.sol";

/// @notice Runs the real `DeployBallast` script against a fork of Unichain Sepolia (chain 1301) and checks its
/// outcome: the hook sits at an address whose flags equal `getHookPermissions()`, the pool is initialised and bound by
/// the same run, the vaults are bound to it in both directions, and a third party cannot initialise another pool (T15, ADR-014). Skips without `RPC_URL`.
/// @custom:requirement R-POOL-6
contract DeployBallastScriptTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant FORK_BLOCK = 68_788_256;

    function test_Script_DeploysHookAtFlaggedAddress_AndInitialisesPool() public {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "RPC_URL not set");
        vm.createSelectFork(rpc, FORK_BLOCK);

        DeployBallast script = new DeployBallast();
        DeployBallast.Deployed memory d = script.run();

        BallastHook hook = BallastHook(d.hook);
        assertEq(
            uint160(d.hook) & Hooks.ALL_HOOK_MASK,
            HookPermissions.flags(HookPermissions.permissions()),
            "address flags"
        );
        assertEq(
            uint160(d.hook) & Hooks.ALL_HOOK_MASK,
            HookPermissions.flags(hook.getHookPermissions()),
            "getHookPermissions"
        );

        Config memory cfg = hook.config();
        assertEq(cfg.initializer, DEFAULT_SENDER, "initializer is the broadcaster");
        assertEq(Currency.unwrap(cfg.collateral), d.collateral);
        assertTrue(d.collateral < d.quote, "collateral is currency0");
        assertTrue(hook.collateralIsCurrency0());
        assertEq(PoolId.unwrap(hook.poolId()), d.poolId);

        // Both directions of the hook/vaults binding hold, with the rest of the graph (T20, ADR-050).
        assertEq(hook.vaults(), d.vaults, "hook.vaults");
        assertEq(address(BallastVaults(d.vaults).hook()), d.hook, "vaults.hook");
        new VerifyBinding().verify(hook, d.lens);

        // The pool exists on the real PoolManager at the intended tick.
        string memory a = vm.readFile("config/addresses.json");
        IPoolManager pm = IPoolManager(vm.parseJsonAddress(a, ".1301.poolManager"));
        PoolKey memory key =
            PoolKey(cfg.collateral, cfg.quote, cfg.fee, cfg.tickSpacing, IHooks(d.hook));
        (uint160 sqrtP, int24 tick,,) = pm.getSlot0(key.toId());
        assertGt(sqrtP, 0, "pool initialised");
        assertEq(tick, d.startTick);
        (LockState st,) = hook.lockState();
        assertEq(uint8(st), uint8(LockState.CALM));

        // A third party cannot initialise (it is already bound, and the initializer check precedes it anyway).
        vm.prank(address(0xBAD));
        vm.expectRevert();
        pm.initialize(key, sqrtP);
    }
}
