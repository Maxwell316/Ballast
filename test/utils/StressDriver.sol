// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HookFixture} from "./HookFixture.sol";
import {ConfigFixture} from "./ConfigFixture.sol";
import {Config, LockState, StressInfo} from "../../src/types/Types.sol";

/// @dev Drives the hook through stress episodes with real swaps. Compressed windows: anchor 1 h, short 5 min,
/// interval 60 s, enter ~305 ticks (300 bps), exit ~151 ticks (150 bps), calm 10 min.
/// Liquidity 1e19 on [-12000, 12000] at tick 0, so selling `CRASH` collateral moves the tick about -630.
abstract contract StressDriver is HookFixture {
    uint256 internal constant CRASH = 3.2e17;
    uint256 internal constant TINY = 1e6;

    function _setUpStress(uint32 maxStressLock) internal {
        _setUpStressSide(maxStressLock, true);
    }

    function _setUpStressSide(uint32 maxStressLock, bool c0) internal {
        Config memory c = ConfigFixture.compressed();
        c.maxStressLock = maxStressLock;
        _setUpDefault(c0, c, 0);
        _provide(-12_000, 12_000, 1e19);
    }

    /// @dev One oracle step: advance `dt` seconds and make a tiny swap (which evaluates stress once per interval).
    function _step(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        _swap(false, TINY); // buy collateral: negligible price effect either way
    }

    function _warmUp() internal {
        for (uint256 i; i < 64; ++i) {
            _step(60);
        }
    }

    function _crash() internal {
        _swap(true, CRASH);
    }

    function _state() internal view returns (LockState s) {
        (s,) = hook.lockState();
    }

    function _stored() internal view returns (LockState) {
        return hook.stressStorage().state;
    }

    /// @dev Steps 60 s at a time until the stored state equals `want` (or `maxSteps`). Returns steps used.
    function _stepUntil(LockState want, uint256 maxSteps) internal returns (uint256 n) {
        while (_stored() != want && n < maxSteps) {
            _step(60);
            ++n;
        }
    }

    function _count(Vm.Log[] memory logs, bytes32 sig) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) ++n;
        }
    }

    bytes32 internal constant SIG_ENTERED = keccak256("StressEntered(int24,int24,uint40)");
    bytes32 internal constant SIG_RECOVERING = keccak256("StressRecovering(uint40)");
    bytes32 internal constant SIG_EXITED = keccak256("StressExited(uint40)");
    bytes32 internal constant SIG_EXPIRED = keccak256("LockExpired(uint40)");
}
