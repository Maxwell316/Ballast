// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Matrix, C0Before, C0After, C1Before, C1After} from "../utils/Matrix.sol";
import {ConfigFixture} from "../utils/ConfigFixture.sol";
import {BallastStandby} from "../../src/BallastStandby.sol";
import {Range} from "../../src/types/Types.sol";

/// @notice Scenario S5: standby funding is exhausted, no further reward is credited, and horizon-netted depth
/// declines as notice-period exits become imminent and then mature.
/// @custom:guarantee G-4 G-5
/// @custom:requirement R-SBY-6 R-VIEW-2
abstract contract DroughtScenarioBase is Matrix {
    uint128 internal constant RATE = 1e12;
    uint256 internal constant LIVE_VECTOR = 397_164_717_108_464_068;

    BallastStandby internal standby;
    uint256 internal vaultId;

    function setUp() public {
        _setUpMatrix(ConfigFixture.compressed(), 0);
        Range[] memory ranges = new Range[](1);
        ranges[0] = Range(-6000, 6000);
        vaultId = vaults.createVault(ranges, 3e17, 0);
        uint128[] memory liquidities = new uint128[](1);
        liquidities[0] = 1e19;
        vaults.seed(vaultId, liquidities, type(uint128).max, type(uint128).max, address(this));

        standby = BallastStandby(address(vaults.standby()));
        quote.mint(ConfigFixture.SPONSOR, 1e24);
        vm.prank(ConfigFixture.SPONSOR);
        quote.approve(address(standby), type(uint256).max);
    }

    function _count(Vm.Log[] memory logs, bytes32 sig) internal pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) ++count;
        }
    }

    function test_Drought_FundDepletesOnce_AndDepthDecaysWithMaturingExits() public {
        vm.prank(ConfigFixture.SPONSOR);
        standby.fundStandby(3e13);
        vm.prank(ConfigFixture.SPONSOR);
        standby.setStandbyRate(RATE);
        vaults.checkpoint(vaultId);

        vm.warp(vm.getBlockTimestamp() + 100);
        vm.recordLogs();
        vaults.checkpoint(vaultId);
        assertEq(standby.standbyInfo().fundBalance, 0);
        assertEq(standby.standbyInfo().totalCredited, 3e13);
        assertEq(
            _count(vm.getRecordedLogs(), keccak256("StandbyDepleted()")),
            1,
            "fund exhaustion is signalled once"
        );

        vm.warp(vm.getBlockTimestamp() + 100);
        vm.recordLogs();
        vaults.checkpoint(vaultId);
        assertEq(
            _count(vm.getRecordedLogs(), keccak256("StandbyDepleted()")),
            0,
            "no repeated depletion event"
        );
        assertEq(standby.standbyInfo().totalCredited, 3e13, "no reward after funding runs out");

        uint256 ticketId = vaults.requestRedeem(vaultId, 2e17);
        uint256 beforeExit = lens.liveDepth(750, 0);
        uint256 beforeMaturity = lens.liveDepth(750, 599);
        uint256 atMaturity = lens.liveDepth(750, 600);
        assertEq(beforeExit, lens.poolAbsorbable(750), "not netted before maturity");
        assertEq(
            atMaturity,
            LIVE_VECTOR * 8 / 10,
            "the exact closed-form 20% ticket is netted at its maturity horizon"
        );
        assertLt(atMaturity, beforeExit, "risk depth falls as the exit approaches");
        assertEq(
            beforeMaturity,
            atMaturity,
            "exit buckets conservatively count the ticket slightly before exact maturity"
        );

        vm.warp(vm.getBlockTimestamp() + 600);
        vaults.claimRedeem(ticketId, address(this));
        uint256 afterExit = lens.liveDepth(750, 0);
        assertEq(afterExit, atMaturity, "matured exit is reflected in current live depth");
        assertApproxEqAbs(afterExit, LIVE_VECTOR * 8 / 10, 4);
    }
}

contract DroughtScenario_C0Before is DroughtScenarioBase, C0Before {}

contract DroughtScenario_C0After is DroughtScenarioBase, C0After {}

contract DroughtScenario_C1Before is DroughtScenarioBase, C1Before {}

contract DroughtScenario_C1After is DroughtScenarioBase, C1After {}
