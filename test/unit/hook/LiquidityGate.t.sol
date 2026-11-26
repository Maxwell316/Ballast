// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VmSafe} from "forge-std/Vm.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BallastHook} from "../../../src/BallastHook.sol";
import {BallastVaults} from "../../../src/BallastVaults.sol";
import {IBallastErrors} from "../../../src/interfaces/IBallastErrors.sol";
import {HookFixture} from "../../utils/HookFixture.sol";
import {BoundDeploy} from "../../utils/BoundDeploy.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {Config} from "../../../src/types/Types.sol";

/// @dev An arbitrary contract that unlocks the PoolManager and calls `modifyLiquidity` itself, the way any integrator
/// or attacker could.
contract UnlockModifier is IUnlockCallback {
    IPoolManager internal immutable pm;
    PoolKey internal key;
    ModifyLiquidityParams internal params;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function go(PoolKey memory key_, ModifyLiquidityParams memory params_) external {
        key = key_;
        params = params_;
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        pm.modifyLiquidity(key, params, "");
        return "";
    }
}

/// @notice G-1 on a local PoolManager: nothing but the vaults contract bound at deployment can add, remove or poke
/// liquidity, and the production hook bytecode contains no liquidity path of its own (T1, T19, ADR-045, ADR-050).
/// The real PositionManager and the deployed routers are exercised in `test/fork/HookOnlyLiquidityFork.t.sol`.
/// @custom:guarantee G-1
/// @custom:requirement R-LIQ-1 R-LIQ-2 R-LIQ-3 R-LIQ-4
contract LiquidityGateTest is HookFixture, BoundDeploy {
    UnlockModifier internal attacker;

    function setUp() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
        _provide(-6000, 6000, 1e19);
        attacker = new UnlockModifier(pm);
        collateral.mint(address(attacker), 1e24);
        quote.mint(address(attacker), 1e24);
    }

    function _forbid(bytes4 callback) internal view returns (bytes memory) {
        return _wrapped(
            callback, abi.encodeWithSelector(IBallastErrors.ExternalLiquidityForbidden.selector)
        );
    }

    function test_RevertWhen_ArbitraryUnlockContract_Adds() public {
        vm.expectRevert(_forbid(IHooks.beforeAddLiquidity.selector));
        attacker.go(key, ModifyLiquidityParams(-600, 600, 1e18, 0));
    }

    function test_RevertWhen_ArbitraryUnlockContract_RemovesOrPokes() public {
        // Same salt as a vault position: the attacker still owns nothing, and the gate fires first.
        vm.expectRevert(_forbid(IHooks.beforeRemoveLiquidity.selector));
        attacker.go(key, ModifyLiquidityParams(-6000, 6000, -1, bytes32(uint256(1) << 8)));
        vm.expectRevert(_forbid(IHooks.beforeRemoveLiquidity.selector));
        attacker.go(key, ModifyLiquidityParams(-6000, 6000, 0, bytes32(uint256(1) << 8)));
    }

    function test_RevertWhen_TheHookItselfIsTheCaller() public {
        // The hook is not the vaults contract: even an add that appears to come from the hook is refused. (Direct
        // callback invocation by a non-PoolManager is refused separately in HookCallbacks.)
        vm.prank(address(hook));
        vm.expectRevert();
        hook.beforeAddLiquidity(address(hook), key, ModifyLiquidityParams(-600, 600, 1, 0), "");
    }

    // ─── T19: the hook contains no liquidity path ───

    function _contains(bytes memory code, bytes4 sel) internal pure returns (bool) {
        if (code.length < 4) return false;
        for (uint256 i; i + 4 <= code.length; ++i) {
            if (
                code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2]
                    && code[i + 3] == sel[3]
            ) return true;
        }
        return false;
    }

    function _prodHook() internal returns (BallastHook prod, BallastVaults prodVaults) {
        Config memory c = ConfigFixture.compressed();
        c.collateral = hook.config().collateral;
        c.quote = hook.config().quote;
        (prod, prodVaults,) = _deployBound(pm, c);
    }

    /// @notice The compiled ABI of the production hook has no `unlock`, `unlockCallback` or `modifyLiquidity`
    /// entrypoint, and no function that could carry out an unlock on its behalf.
    function test_HookAbi_HasNoLiquidityEntrypoints() public view {
        string memory json = vm.readFile("out/BallastHook.sol/BallastHook.json");
        string[] memory names = vm.parseJsonKeys(json, ".methodIdentifiers");
        for (uint256 i; i < names.length; ++i) {
            bytes memory n = bytes(names[i]);
            assertFalse(_startsWith(n, "unlock"), "hook ABI has unlock*");
            assertFalse(_startsWith(n, "modifyLiquidity"), "hook ABI has modifyLiquidity");
            assertFalse(_startsWith(n, "settle"), "hook ABI has settle");
            assertFalse(_startsWith(n, "take"), "hook ABI has take");
        }
        assertGt(names.length, 5, "control: the ABI was actually read");
    }

    function _startsWith(bytes memory s, string memory prefix) internal pure returns (bool) {
        bytes memory p = bytes(prefix);
        if (s.length < p.length) return false;
        for (uint256 i; i < p.length; ++i) {
            if (s[i] != p[i]) return false;
        }
        return true;
    }

    /// @notice The hook runtime code carries neither the `unlock` call selector nor the `unlockCallback` selector.
    /// @dev A literal scan is best-effort for calls: the optimizer may build a selector constant arithmetically, so
    /// `modifyLiquidity`'s selector is absent from the vaults' runtime too (it is called there) and cannot be a
    /// positive control. `unlock` and `unlockCallback` are present in the vaults' code and are controlled. The
    /// behavioural test below is the stronger evidence.
    function test_HookBytecode_HasNoUnlockSelectors() public {
        (BallastHook prod, BallastVaults prodVaults) = _prodHook();
        bytes memory hookCode = address(prod).code;
        bytes memory vaultsCode = address(prodVaults).code;
        bytes4 unlock = IPoolManager.unlock.selector;
        bytes4 cb = IUnlockCallback.unlockCallback.selector;
        assertFalse(_contains(hookCode, IPoolManager.modifyLiquidity.selector), "modifyLiquidity");
        assertFalse(_contains(hookCode, unlock), "hook calls unlock");
        assertFalse(_contains(hookCode, cb), "hook implements unlockCallback");
        assertTrue(_contains(vaultsCode, unlock), "control: vaults call unlock");
        assertTrue(_contains(vaultsCode, cb), "control: vaults implement unlockCallback");
        assertTrue(_contains(hookCode, IHooks.beforeSwap.selector), "control: hook has beforeSwap");
    }

    /// @notice Behavioural proof over the exercised paths: through initialisation, swaps in both directions with time
    /// passing (oracle writes, stress evaluation), a poke and a vault operation, every call the hook makes goes to the
    /// PoolManager and is a storage read.
    function test_HookCalls_AreOnlyPoolManagerReads() public {
        vm.startStateDiffRecording();
        vm.warp(vm.getBlockTimestamp() + 120);
        _swap(true, 1e16);
        vm.warp(vm.getBlockTimestamp() + 120);
        _swap(false, 1e16);
        hook.pokeStress();
        vaults.deposit(1, 1e15, type(uint128).max, type(uint128).max, address(this));
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        uint256 calls;
        for (uint256 i; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory a = accesses[i];
            bool isCall = a.kind == VmSafe.AccountAccessKind.Call
                || a.kind == VmSafe.AccountAccessKind.StaticCall;
            if (a.accessor != address(hook) || !isCall) continue;
            ++calls;
            assertEq(a.account, address(pm), "hook called something other than the PoolManager");
            bytes4 sel = bytes4(a.data);
            assertTrue(
                sel == bytes4(0x1e2eaeaf) || sel == bytes4(0x35fd631a) || sel == bytes4(0xdbd035ff)
                    || sel == bytes4(0xf135baaa),
                "hook made a non-read call to the PoolManager"
            );
        }
        assertGt(calls, 0, "control: the hook did call the PoolManager");
    }
}
