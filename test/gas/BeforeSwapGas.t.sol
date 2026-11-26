// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "../utils/HookFixture.sol";
import {ConfigFixture} from "../utils/ConfigFixture.sol";

/// @notice Gas of the real `beforeSwap` through `PoolManager.swap` (ADR-038). The probe in the harness measures the
/// gas inside `_beforeSwap`; `vm.cool` makes the hook's and PoolManager's storage cold as in a fresh transaction.
contract BeforeSwapGasTest is HookFixture {
    function setUp() public {
        _setUpDefault(true, ConfigFixture.prodLike(), 0);
        hook.modifyForTest(-6000, 6000, 1e18, bytes32(uint256(1)));
    }

    function _measure() internal returns (uint256) {
        vm.cool(address(hook));
        vm.cool(address(pm));
        _swap(true, 1e12);
        return hook.lastBeforeSwapGas();
    }

    function test_Gas_NoUpdate_SameTimestamp() public {
        _swap(true, 1e12);
        emit log_named_uint("beforeSwap: same timestamp (no update)", _measure());
    }

    function test_Gas_UpdateOnly_NoSnapshot() public {
        _swap(true, 1e12);
        vm.warp(block.timestamp + 10);
        emit log_named_uint("beforeSwap: update only (no snapshot)", _measure());
    }

    function test_Gas_Snapshot_Cold() public {
        _swap(true, 1e12);
        vm.warp(block.timestamp + 61);
        emit log_named_uint("beforeSwap: update+snapshot+eval (cold oracle)", _measure());
    }

    function test_Gas_Snapshot_WarmEval() public {
        for (uint256 i; i < 1500; ++i) {
            vm.warp(block.timestamp + 60);
            _swap(i % 2 == 0, 1e12);
        }
        vm.warp(block.timestamp + 61);
        emit log_named_uint("beforeSwap: update+snapshot+eval (warm, ring filling)", _measure());
    }

    function test_Gas_Snapshot_WarmEval_AfterWrap() public {
        for (uint256 i; i < 1700; ++i) {
            vm.warp(block.timestamp + 60);
            _swap(i % 2 == 0, 1e12);
        }
        vm.warp(block.timestamp + 61);
        emit log_named_uint("beforeSwap: update+snapshot+eval (warm, wrapped ring)", _measure());
    }
}
