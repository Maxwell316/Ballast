// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StressDriver} from "../utils/StressDriver.sol";
import {LockState} from "../../src/types/Types.sol";

/// @notice A liquidation-sized sell must always execute: Ballast's stress logic can never block a swap (R-STR-10,
/// and the premise of the product: the lock holds exits, not trades). The same sell is executed in STRESS,
/// RECOVERING and after lock expiry, in both collateral orderings.
/// @custom:requirement R-STR-10
contract LiquidationDuringStressTest is StressDriver {
    uint256 internal constant LIQUIDATION = 4e17;

    function _liquidate() internal {
        uint256 before_ = quote.balanceOf(address(this));
        int24 tickBefore = _tick();
        _swap(true, LIQUIDATION);
        assertGt(quote.balanceOf(address(this)), before_, "liquidator received quote");
        assertLt(_tick(), tickBefore, "price moved in the liquidation direction");
    }

    function test_LargeSell_ExecutesInStress() public {
        _setUpStress(1 hours);
        _warmUp();
        _crash();
        _stepUntil(LockState.STRESS, 20);
        assertEq(uint8(_stored()), uint8(LockState.STRESS));
        _liquidate();
    }

    function test_LargeSell_ExecutesInRecovering() public {
        _setUpStress(1 hours);
        _warmUp();
        _crash();
        _stepUntil(LockState.STRESS, 20);
        _stepUntil(LockState.RECOVERING, 80);
        assertEq(uint8(_stored()), uint8(LockState.RECOVERING));
        _liquidate();
    }

    function test_LargeSell_ExecutesAfterLockExpiry() public {
        _setUpStress(30 minutes);
        _warmUp();
        _crash();
        _stepUntil(LockState.STRESS, 20);
        uint40 started = hook.stressStorage().stressStartedAt;
        while (vm.getBlockTimestamp() < started + 30 minutes + 120) _step(60);
        assertFalse(hook.stressInfo().lockActive, "expired");
        _liquidate();
    }

    /// @notice The sell that itself triggers the stress (the crash) also executes, and so does one in the very
    /// transaction that records the transition.
    function test_LargeSell_ExecutesWhileTheEvaluationIsEnteringStress() public {
        _setUpStress(1 hours);
        _warmUp();
        _crash();
        vm.warp(vm.getBlockTimestamp() + 200);
        assertEq(uint8(_stored()), uint8(LockState.CALM));
        _liquidate(); // this swap's beforeSwap evaluates and stores STRESS
        assertEq(uint8(_stored()), uint8(LockState.STRESS));
    }
}
