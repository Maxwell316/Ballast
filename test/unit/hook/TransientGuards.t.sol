// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookFixture} from "../../utils/HookFixture.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {BallastHookHarness} from "../../utils/BallastHookHarness.sol";
import {IBallastErrors} from "../../../src/interfaces/IBallastErrors.sol";
import {MockERC20} from "../../utils/MockERC20.sol";

/// @dev One external call = one transaction. Used to put a swap and a vault operation in a single transaction.
contract TxProbe {
    function swapThenVaultOp(
        PoolSwapTest router,
        PoolKey memory key,
        bool zeroForOne,
        BallastHookHarness h
    ) external {
        _swap(router, key, zeroForOne);
        h.enterVaultOpForTest();
    }

    function vaultOpThenSwap(
        PoolSwapTest router,
        PoolKey memory key,
        bool zeroForOne,
        BallastHookHarness h
    ) external {
        h.enterVaultOpForTest();
        _swap(router, key, zeroForOne);
    }

    function twoSwaps(PoolSwapTest router, PoolKey memory key) external {
        _swap(router, key, true);
        _swap(router, key, false);
    }

    function twoVaultOps(BallastHookHarness h) external {
        h.enterVaultOpForTest();
        h.enterVaultOpForTest();
    }

    function _swap(PoolSwapTest router, PoolKey memory key, bool zeroForOne) private {
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1e6,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}

/// @notice The D-9 transaction guards and the reentrancy lock (R-TX-1..3, INV-14).
/// @dev Tests that prove a flag does not outlive its transaction need each top-level call to be its own transaction.
/// Forge 1.8.4 clears transient storage between top-level calls (verified: `test_ProbeSeesSeparateTransactions`,
/// and the same results with `--isolate`). If a future Foundry stops doing so, that probe fails loudly instead of the
/// reset tests passing vacuously.
/// @custom:requirement R-TX-1 R-TX-2 R-TX-3
contract TransientGuardsTest is HookFixture {
    TxProbe internal probe;
    bool internal separateTx;

    function setUp() public {
        _setUpDefault(true, ConfigFixture.prodLike(), 0);
        hook.modifyForTest(-6000, 6000, 1e19, bytes32(uint256(1)));
        probe = new TxProbe();
        collateral.mint(address(probe), 1e24);
        quote.mint(address(probe), 1e24);
        vm.startPrank(address(probe));
        collateral.approve(address(swapRouter), type(uint256).max);
        quote.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Probe: does a flag set by one call survive to the next call of this test?
        hook.enterVaultOpForTest();
        (, bool stillSet,) = hook.flags();
        separateTx = !stillSet;
    }

    /// @notice Guards the guards: a transient flag set by one top-level call must be gone in the next.
    function test_ProbeSeesSeparateTransactions() public view {
        assertTrue(
            separateTx, "test runner does not separate transactions; reset tests would be vacuous"
        );
    }

    // ─── same-transaction guards ───

    /// @custom:requirement R-TX-2
    function test_RevertWhen_SwapThenVaultOp_InOneTransaction() public {
        vm.expectRevert(IBallastErrors.SwapInSameTransaction.selector);
        probe.swapThenVaultOp(swapRouter, key, true, hook);
        vm.expectRevert(IBallastErrors.SwapInSameTransaction.selector);
        probe.swapThenVaultOp(swapRouter, key, false, hook);
    }

    /// @custom:requirement R-TX-1
    function test_RevertWhen_VaultOpThenSwap_InOneTransaction() public {
        bytes memory wrapped = _wrapped(
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(IBallastErrors.VaultOpInSameTransaction.selector)
        );
        vm.expectRevert(wrapped);
        probe.vaultOpThenSwap(swapRouter, key, true, hook);
    }

    function test_TwoSwaps_AndTwoVaultOps_InOneTransaction_AreFine() public {
        probe.twoSwaps(swapRouter, key);
        probe.twoVaultOps(hook);
    }

    // ─── guards do not outlive the transaction ───

    /// @custom:requirement R-TX-1
    function test_VaultOpFlag_DoesNotBlockSwapInLaterTransaction() public {
        hook.enterVaultOpForTest(); // transaction A
        _swap(true, 1e6); // transaction B
        (bool swapped, bool vaultOp,) = hook.flags();
        assertFalse(swapped, "SWAPPED cleared after its transaction");
        assertFalse(vaultOp);
    }

    /// @custom:requirement R-TX-2
    function test_SwapFlag_DoesNotBlockVaultOpInLaterTransaction() public {
        _swap(true, 1e6); // transaction A
        hook.enterVaultOpForTest(); // transaction B
    }

    // ─── reentrancy ───

    /// @custom:requirement R-TX-3
    function test_RevertWhen_Reentrant() public {
        hook.setProbeReentrancy(true);
        vm.expectRevert(IBallastErrors.Reentrancy.selector);
        hook.guardedCall();
    }

    /// @custom:requirement R-TX-3
    function test_Lock_IsReleasedAfterCall() public {
        hook.guardedCall();
        hook.guardedCall();
        (,, bool lock) = hook.flags();
        assertFalse(lock);
    }
}
