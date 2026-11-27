// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Matrix, C0Before, C1Before} from "../../utils/Matrix.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {BallastLens} from "../../../src/periphery/BallastLens.sol";
import {SupplyCapAdvisor} from "../../../src/periphery/SupplyCapAdvisor.sol";
import {IBallastHook} from "../../../src/interfaces/IBallastHook.sol";
import {IBallastDepthOracle} from "../../../src/interfaces/IBallastDepthOracle.sol";
import {LockState, Range} from "../../../src/types/Types.sol";

/// @notice Construction-order independence (ADR-058): the periphery is built before the pool is initialised (as the
/// deploy script does) and again after, over the same state; the two must be indistinguishable, in both collateral
/// orderings. Also pins what a consumer sees before the pool is bound: empty, not wrong.
/// @dev The deploy script builds the lens and the advisor before `pool.initialize`, so the "before" lens is the one that
/// ships. A lens that derived the liquidation direction from the hook's binding state would be built with the wrong
/// direction in exactly this case (the bug ADR-058 fixed); the equality tests below fail for it.
/// @custom:requirement R-VIEW-4
abstract contract LensConstructionBase is Matrix {
    BallastLens internal lensBefore;
    SupplyCapAdvisor internal advisorBefore;

    function setUp() public {
        _deployInfra();
        _tokens(_c0(), 18, 6);
        _deployHook(ConfigFixture.compressed()); // builds `lens` before the pool exists
        lensBefore = lens;
        advisorBefore = new SupplyCapAdvisor(IBallastDepthOracle(address(lens)));
    }

    function _bringUp() internal {
        _initPool(0);
        collateral.mint(address(this), 1e30);
        quote.mint(address(this), 1e30);
        collateral.approve(address(swapRouter), type(uint256).max);
        quote.approve(address(swapRouter), type(uint256).max);
        collateral.approve(address(vaults), type(uint256).max);
        quote.approve(address(vaults), type(uint256).max);
    }

    /// @notice Before the pool is bound every view answers "nothing here", without reverting and without a wrong value.
    function test_ViewsBeforeInitialisation_AreEmpty() public view {
        assertEq(lensBefore.vaultCount(), 0);
        assertEq(lensBefore.committedDepth(), 0);
        assertEq(lensBefore.liveDepth(750, 0), 0);
        assertEq(lensBefore.liveDepth(750, 3600), 0);
        assertEq(lensBefore.poolAbsorbable(750), 0);
        (LockState s, uint40 until) = lensBefore.lockState();
        assertEq(uint8(s), uint8(LockState.CALM));
        assertEq(until, 0);
        assertEq(advisorBefore.suggestedCap(2e18, 750, 0), 0);
    }

    /// @notice The direction a consumer reads from the hook does not depend on whether the pool is bound yet.
    function test_HookCollateralOrdering_IsReadableBeforeBinding() public view {
        assertEq(hook.collateralIsCurrency0(), _c0(), "ordering flag before binding");
    }

    function test_LensBuiltBeforeInit_EqualsLensBuiltAfterInit_OverTheSameState() public {
        _bringUp();
        BallastLens lensAfter = new BallastLens(IBallastHook(address(hook)), vaults.shareToken());
        SupplyCapAdvisor advisorAfter =
            new SupplyCapAdvisor(IBallastDepthOracle(address(lensAfter)));
        // Two vaults, one with an exit ticket, then a sale that moves the spot.
        Range[] memory r = new Range[](2);
        r[0] = Range(-6000, 6000);
        r[1] = Range(-1200, 3000);
        uint256 v1 = vaults.createVault(r, 3e17, 0);
        uint128[] memory l = new uint128[](2);
        l[0] = 1e19;
        l[1] = 4e18;
        vaults.seed(v1, l, type(uint128).max, type(uint128).max, address(this));
        vaults.requestRedeem(v1, 2e17);
        vm.warp(vm.getBlockTimestamp() + 300);
        _swap(true, 4e17);

        assertGt(lensBefore.liveDepth(750, 600), 0, "non-trivial state");
        assertEq(lensBefore.committedDepth(), lensAfter.committedDepth(), "committedDepth");
        assertEq(lensBefore.poolAbsorbable(750), lensAfter.poolAbsorbable(750), "poolAbsorbable");
        assertEq(lensBefore.vaultDepth(v1), lensAfter.vaultDepth(v1), "vaultDepth");
        for (uint32 h = 0; h <= 1200; h += 300) {
            assertEq(lensBefore.liveDepth(750, h), lensAfter.liveDepth(750, h), "liveDepth");
            assertEq(
                advisorBefore.suggestedCap(2e18, 750, h),
                advisorAfter.suggestedCap(2e18, 750, h),
                "suggestedCap"
            );
        }
        (uint128 d0, uint128 k0, bool b0) = lensBefore.vaultStatus(v1);
        (uint128 d1, uint128 k1, bool b1) = lensAfter.vaultStatus(v1);
        assertEq(d0, d1);
        assertEq(k0, k1);
        assertEq(b0, b1);
    }
}

contract LensConstructionTest_C0 is LensConstructionBase, C0Before {}

contract LensConstructionTest_C1 is LensConstructionBase, C1Before {}
