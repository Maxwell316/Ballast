// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BallastHook} from "../../src/BallastHook.sol";
import {Config} from "../../src/types/Types.sol";
import {Observations} from "../../src/libraries/Observations.sol";
import {Transient} from "../../src/libraries/Transient.sol";

/// @notice TEST-ONLY subclass of `BallastHook`. It lives in `test/` and is never deployed or compiled into `src/`
/// (the release bytecode contains none of this). It adds: (1) liquidity entrypoints that perform the hook's own
/// `modifyLiquidity` inside an unlock, standing in for vault operations until M3; (2) entrypoints that exercise the
/// D-9 and reentrancy guards; (3) a gas probe around `_beforeSwap`.
contract BallastHookHarness is BallastHook, IUnlockCallback {
    using CurrencySettler for Currency;

    PoolKey internal _key;
    uint256 public lastBeforeSwapGas;
    uint256 public reentrantAttempts;
    bool public probeReentrancy;

    constructor(IPoolManager pm, Config memory cfg) BallastHook(pm, cfg) {}

    // ─── (1) hook-owned liquidity, test stand-in for M3 ───

    function setKey(PoolKey calldata key) external {
        _key = key;
    }

    /// @notice The hook adds (liquidityDelta > 0) or removes liquidity on its own account, settling in tokens.
    function modifyForTest(int24 lower, int24 upper, int256 liquidityDelta, bytes32 salt) external {
        poolManager.unlock(abi.encode(lower, upper, liquidityDelta, salt));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (int24 lower, int24 upper, int256 liq, bytes32 salt) =
            abi.decode(data, (int24, int24, int256, bytes32));
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            _key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: liq, salt: salt
            }),
            ""
        );
        _settle(_key.currency0, d.amount0());
        _settle(_key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency c, int128 amt) private {
        if (amt < 0) c.settle(poolManager, address(this), uint256(uint128(-amt)), false);
        else if (amt > 0) c.take(poolManager, address(this), uint256(uint128(amt)), false);
    }

    // ─── (2) guard probes ───

    function enterVaultOpForTest() external {
        _enterVaultOp();
    }

    /// @notice Sets the VAULT_OP flag (via the guard) and then, in the same call, performs a swap through `target`.
    function guardedCall() external nonReentrant {
        if (probeReentrancy) {
            reentrantAttempts++;
            this.guardedCall();
        }
    }

    function setProbeReentrancy(bool on) external {
        probeReentrancy = on;
    }

    // ─── state readers for tests ───

    function obsState() external view returns (Observations.State memory) {
        return _obs;
    }

    function obsLength() external view returns (uint256) {
        return _observations.length;
    }

    function obsAt(uint256 i) external view returns (Observations.Observation memory) {
        return _observations[i];
    }

    function stressStorage() external view returns (StressStorage memory) {
        return _stress;
    }

    function flags() external view returns (bool swapped, bool vaultOp, bool lock) {
        return (
            Transient.get(Transient.SWAPPED),
            Transient.get(Transient.VAULT_OP),
            Transient.get(Transient.LOCK)
        );
    }

    // ─── (3) gas probe ───

    function _beforeSwap(address s, PoolKey calldata key, SwapParams calldata p, bytes calldata h)
        internal
        override
        returns (bytes4 sel, BeforeSwapDelta d, uint24 fee)
    {
        uint256 g = gasleft();
        (sel, d, fee) = super._beforeSwap(s, key, p, h);
        lastBeforeSwapGas = g - gasleft();
    }
}
