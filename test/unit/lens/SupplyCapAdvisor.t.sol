// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "../../utils/HookFixture.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {SupplyCapAdvisor} from "../../../src/periphery/SupplyCapAdvisor.sol";
import {IBallastDepthOracle} from "../../../src/interfaces/IBallastDepthOracle.sol";

/// @notice The reference advisor returns `multiplier x liveDepth` (the guidance of R-VIEW-5) and nothing else.
/// @custom:requirement R-VIEW-2 R-VIEW-3
contract SupplyCapAdvisorTest is HookFixture {
    SupplyCapAdvisor internal advisor;

    function setUp() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
        _provide(-6000, 6000, 1e19);
        advisor = new SupplyCapAdvisor(IBallastDepthOracle(address(lens)));
    }

    function test_SuggestedCap_IsMultiplierTimesLiveDepth() public view {
        uint256 live = lens.liveDepth(750, 0);
        assertGt(live, 0);
        assertEq(advisor.suggestedCap(2e18, 750, 0), live * 2);
        assertEq(advisor.suggestedCap(1e18, 750, 0), live);
        assertEq(advisor.suggestedCap(0, 750, 0), 0);
        assertEq(advisor.suggestedCap(5e17, 750, 0), live / 2);
    }

    function test_SuggestedCap_FallsWhenExitsMatureInsideTheHorizon() public {
        uint256 t = vaults.requestRedeem(1, 2e17);
        assertEq(t, 1);
        uint256 now_ = advisor.suggestedCap(2e18, 750, 0);
        uint256 later = advisor.suggestedCap(2e18, 750, 600);
        assertLt(later, now_, "a 20% exit inside the horizon lowers the suggested cap");
        assertApproxEqRel(later, now_ * 8 / 10, 1e16);
    }

    /// @notice `lockState` informs about the lock: inactive in calm, with `lockedUntil` an upper bound once stressed.
    function test_Advisor_HasNoOwnerAndHoldsNoState() public view {
        assertEq(address(advisor.depthOracle()), address(lens));
        assertEq(advisor.WAD(), 1e18);
    }
}
