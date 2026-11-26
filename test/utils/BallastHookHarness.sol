// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BallastHook} from "../../src/BallastHook.sol";
import {Config} from "../../src/types/Types.sol";
import {Observations} from "../../src/libraries/Observations.sol";
import {Transient} from "../../src/libraries/Transient.sol";

/// @notice TEST-ONLY subclass of `BallastHook`. It lives in `test/` and is never deployed or compiled into `src/`
/// (the release bytecode contains none of this). It adds: (1) liquidity entrypoints that perform the hook's own
/// state readers and a gas probe around `_beforeSwap`. It adds no liquidity path (T19 concerns the production contract).
contract BallastHookHarness is BallastHook {
    uint256 public lastBeforeSwapGas;

    constructor(IPoolManager pm, Config memory cfg, address vaults_) BallastHook(pm, cfg, vaults_) {}

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

    function flags() external view returns (bool swapped, bool vaultOp) {
        return (Transient.get(Transient.SWAPPED), Transient.get(Transient.VAULT_OP));
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
