// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Matrix, C0Before, C0After, C1Before, C1After} from "../../utils/Matrix.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {SupplyCapAdvisor} from "../../../src/periphery/SupplyCapAdvisor.sol";
import {IBallastDepthOracle} from "../../../src/interfaces/IBallastDepthOracle.sol";
import {Position} from "../../../src/types/Types.sol";

/// @notice The reference advisor returns `multiplier x liveDepth` (the guidance of R-VIEW-5) and nothing else, and the
/// depth it multiplies is right.
/// @dev Expected values are independent of the lens, the vaults and `DepthMath`:
/// - `LIVE_VECTOR` is a closed form evaluated off-chain with 70-digit decimals: for liquidity 1e19 over [-6000, 6000]
///   at tick 0, a 750 bps band is 779 ticks (`test/data/band_ticks_ref.json`) and the absorbable collateral is
///   `L x (1.0001^(779/2) - 1)` = 397164717108464068.12 raw units, the same for both collateral orderings by symmetry;
/// - a real swap through a plain pool with the same position (BruteForce) measures the same figure on chain.
/// Run over both collateral orderings and both lens construction orders (Matrix).
/// @custom:requirement R-VIEW-2 R-VIEW-3
abstract contract SupplyCapAdvisorBase is Matrix {
    using StateLibrary for IPoolManager;

    /// @dev floor(1e19 x (1.0001^389.5 - 1)); see the contract comment.
    uint256 internal constant LIVE_VECTOR = 397_164_717_108_464_068;
    /// @dev Allowance around the vector: the TickMath square roots round, at most a couple of wei at this size.
    uint256 internal constant VECTOR_TOL = 4;

    SupplyCapAdvisor internal advisor;

    function setUp() public {
        _setUpMatrix(ConfigFixture.compressed(), 0);
        _provide(-6000, 6000, 1e19);
        advisor = new SupplyCapAdvisor(IBallastDepthOracle(address(lens)));
    }

    function test_LiveDepth_MatchesTheVector_AndABruteForceSwap() public {
        uint256 live = lens.liveDepth(750, 0);
        assertApproxEqAbs(live, LIVE_VECTOR, VECTOR_TOL, "closed-form vector");
        Position[] memory ps = new Position[](1);
        ps[0] = Position(-6000, 6000, 1e19);
        (uint160 sqrtP, int24 spot,,) = IPoolManager(address(pm)).getSlot0(pid);
        Plain memory p = _plainPool(ps, sqrtP, cfg.fee, 0);
        (uint256 narrow, uint256 wide,) = _absorbTwoStage(p, _farEdge(spot, 750));
        assertLe(live, wide, "never above the measured absorbable collateral");
        assertGe(live + tolerance(1), narrow, "and not below it by more than the allowance");
    }

    function test_SuggestedCap_IsMultiplierTimesLiveDepth() public view {
        uint256 live = lens.liveDepth(750, 0);
        assertApproxEqAbs(live, LIVE_VECTOR, VECTOR_TOL);
        assertEq(advisor.suggestedCap(2e18, 750, 0), live * 2);
        assertEq(advisor.suggestedCap(1e18, 750, 0), live);
        assertEq(advisor.suggestedCap(0, 750, 0), 0);
        assertEq(advisor.suggestedCap(5e17, 750, 0), live / 2);
        // And in absolute terms, not only relative to the lens:
        assertApproxEqAbs(advisor.suggestedCap(2e18, 750, 0), 2 * LIVE_VECTOR, 2 * VECTOR_TOL);
    }

    function test_SuggestedCap_FallsWhenExitsMatureInsideTheHorizon() public {
        uint256 t = vaults.requestRedeem(1, 2e17);
        assertEq(t, 1);
        uint256 now_ = advisor.suggestedCap(2e18, 750, 0);
        uint256 later = advisor.suggestedCap(2e18, 750, 600);
        assertLt(later, now_, "a 20% exit inside the horizon lowers the suggested cap");
        // 1e18 shares in total, 2e17 exiting at maturity (now + 600 s = the horizon): 80% remains.
        assertApproxEqAbs(
            now_, 2 * LIVE_VECTOR, 2 * VECTOR_TOL, "horizon 0: the ticket is not yet counted"
        );
        assertApproxEqAbs(
            later,
            2 * (LIVE_VECTOR * 8 / 10),
            2 * VECTOR_TOL,
            "horizon 600: 80% of the depth remains"
        );
    }

    function test_Advisor_HasNoOwnerAndHoldsNoState() public view {
        assertEq(address(advisor.depthOracle()), address(lens));
        assertEq(advisor.WAD(), 1e18);
    }
}

contract SupplyCapAdvisorTest_C0Before is SupplyCapAdvisorBase, C0Before {}

contract SupplyCapAdvisorTest_C0After is SupplyCapAdvisorBase, C0After {}

contract SupplyCapAdvisorTest_C1Before is SupplyCapAdvisorBase, C1Before {}

contract SupplyCapAdvisorTest_C1After is SupplyCapAdvisorBase, C1After {}
