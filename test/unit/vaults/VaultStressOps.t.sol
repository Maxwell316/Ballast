// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StressDriver} from "../../utils/StressDriver.sol";
import {IBallastErrors} from "../../../src/interfaces/IBallastErrors.sol";
import {LockState, PositionView, Range, VaultView} from "../../../src/types/Types.sol";

/// @notice Operations whose behaviour depends on the stress state: `deployIdle` (idle only, never reduces liquidity),
/// coverage not enforced under stress, and `liveDepth` monotone in the horizon (M5; R-VLT-11, R-COV-4, INV-10).
/// @dev Fixture: vault 1 over [-12000, 12000], liquidity 1e19, commitment 0; the test first re-ranges it down to 8e18 in
/// CALM so that recovered tokens sit in idle.
/// @custom:requirement R-VLT-11 R-COV-1 R-COV-4 R-VIEW-2
/// @custom:invariant INV-10
contract VaultStressOpsTest is StressDriver {
    uint256 internal v = 1;

    function _setUpIdle(uint32 maxLock) internal {
        _setUpStress(maxLock);
        Range[] memory r = new Range[](1);
        r[0] = Range(-12_000, 12_000);
        uint128[] memory l = new uint128[](1);
        l[0] = 8e18;
        vaults.rerange(v, r, l);
        assertGt(lens.vault(v).idle0 + lens.vault(v).idle1, 0, "idle funded by the shrink");
    }

    function _toStress() internal {
        _warmUp();
        _crash();
        _stepUntil(LockState.STRESS, 20);
        assertEq(uint8(_stored()), uint8(LockState.STRESS));
    }

    // ─── deployIdle ───

    function test_DeployIdle_InCalm_UsesIdleOnly_AndAddsAPosition() public {
        _setUpIdle(1 hours);
        VaultView memory before_ = lens.vault(v);
        uint128 main = lens.positionsOf(v)[0].liquidity;
        vaults.deployIdle(v, Range(-600, 600), 1e17);
        VaultView memory after_ = lens.vault(v);
        PositionView[] memory p = lens.positionsOf(v);
        assertEq(p.length, 2);
        assertEq(p[1].liquidity, 1e17);
        assertEq(p[0].liquidity, main, "existing liquidity untouched");
        assertEq(after_.positionCount, 2);
        assertLt(after_.idle0 + after_.idle1, before_.idle0 + before_.idle1, "paid from idle");
        assertEq(after_.totalShares, before_.totalShares, "shares are untouched");
    }

    function test_DeployIdle_InStress_StillWorks_AndNeverReducesLiquidity() public {
        _setUpIdle(1 hours);
        _toStress();
        uint128 main = lens.positionsOf(v)[0].liquidity;
        // Price has fallen to about tick -630: a range around it needs both tokens, both held in idle.
        vaults.deployIdle(v, Range(-1200, 600), 5e16);
        PositionView[] memory p = lens.positionsOf(v);
        assertEq(p.length, 2);
        assertEq(p[0].liquidity, main, "no liquidity left any position (INV-6)");
        // Adding to the same range again reuses the slot instead of creating a new position.
        vaults.deployIdle(v, Range(-1200, 600), 1e16);
        p = lens.positionsOf(v);
        assertEq(p.length, 2);
        assertEq(p[1].liquidity, 5e16 + 1e16);
    }

    function test_RevertWhen_DeployIdle_Invalid() public {
        _setUpIdle(1 hours);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(IBallastErrors.NotCurator.selector, address(0xBAD)));
        vaults.deployIdle(v, Range(-600, 600), 1e17);
        vm.expectRevert(IBallastErrors.InvalidLiquidities.selector);
        vaults.deployIdle(v, Range(-600, 600), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IBallastErrors.InvalidRange.selector, int24(-601), int24(600))
        );
        vaults.deployIdle(v, Range(-601, 600), 1e17);
        // More than idle can pay for.
        vm.expectRevert(IBallastErrors.InsufficientIdle.selector);
        vaults.deployIdle(v, Range(-600, 600), 5e19);
    }

    function test_RevertWhen_DeployIdle_PositionLimit() public {
        _setUpIdle(1 hours);
        for (uint256 i = 1; i < 8; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            vaults.deployIdle(v, Range(-int24(int256(60 * i)), 60), 1e12);
        }
        assertEq(lens.positionsOf(v).length, 8);
        vm.expectRevert(IBallastErrors.TooManyPositions.selector);
        vaults.deployIdle(v, Range(-6000, 60), 1e12);
    }

    // ─── coverage is not enforced under stress (R-COV-4) ───

    function test_Coverage_IsNotEnforcedUnderStress_AndTheGraceStartsFreshAfterCalm() public {
        _setUpStress(2 hours);
        _warmUp();
        vaults.setCommitment(v, 1e18); // far above what the vault commits (about 0.04 of liquidity)
        _crash();
        _stepUntil(LockState.STRESS, 20);
        // Under stress the vault is below its commitment, yet nothing starts, flags or counts.
        vaults.checkpoint(v);
        vm.warp(vm.getBlockTimestamp() + 400);
        vaults.checkpoint(v);
        assertEq(lens.vault(v).breachSince, 0, "no breach under stress");
        assertEq(lens.vaultRecord(v).breachCount, 0);
        // After calm returns the curator gets a full grace period before anything is flagged.
        _stepUntil(LockState.CALM, 200);
        assertEq(uint8(_stored()), uint8(LockState.CALM));
        vaults.checkpoint(v); // starts the clock
        assertEq(lens.vault(v).breachSince, 0);
        vm.warp(vm.getBlockTimestamp() + 200);
        vaults.checkpoint(v);
        assertEq(lens.vault(v).breachSince, 0, "still inside the 300 s grace");
        vm.warp(vm.getBlockTimestamp() + 200);
        vaults.checkpoint(v);
        assertGt(lens.vault(v).breachSince, 0, "flagged only after a full grace in calm");
    }

    // ─── INV-10 ───

    function _tickets() internal {
        vaults.requestRedeem(v, 5e16);
        vm.warp(vm.getBlockTimestamp() + 200);
        vaults.requestRedeem(v, 7e16);
        vm.warp(vm.getBlockTimestamp() + 300);
        vaults.requestRedeem(v, 1e16);
    }

    function _checkMonotone(uint16 impact, uint32 h1, uint32 h2) internal view {
        (uint32 lo, uint32 hi) = h1 <= h2 ? (h1, h2) : (h2, h1);
        uint256 a = lens.liveDepth(impact, lo);
        uint256 b = lens.liveDepth(impact, hi);
        assertLe(b, a, "INV-10: a longer horizon never shows more depth");
        assertLe(
            a, lens.poolAbsorbable(impact), "live depth never exceeds the pool's absorbable depth"
        );
    }

    function testFuzz_LiveDepth_IsMonotoneInTheHorizon_Calm(uint16 impact, uint32 h1, uint32 h2)
        public
    {
        _setUpStress(1 hours);
        _tickets();
        _checkMonotone(
            uint16(bound(impact, 50, 2500)),
            uint32(bound(h1, 0, 3 days)),
            uint32(bound(h2, 0, 3 days))
        );
    }

    function testFuzz_LiveDepth_IsMonotoneInTheHorizon_Stress(uint16 impact, uint32 h1, uint32 h2)
        public
    {
        _setUpStress(1 hours);
        _tickets();
        _warmUp();
        _crash();
        _stepUntil(LockState.STRESS, 20);
        _checkMonotone(
            uint16(bound(impact, 50, 2500)),
            uint32(bound(h1, 0, 3 days)),
            uint32(bound(h2, 0, 3 days))
        );
    }
}
