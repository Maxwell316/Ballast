// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Matrix, C0Before, C0After, C1Before, C1After} from "../utils/Matrix.sol";
import {ConfigFixture} from "../utils/ConfigFixture.sol";
import {BallastStandby} from "../../src/BallastStandby.sol";
import {IBallastEvents} from "../../src/interfaces/IBallastEvents.sol";
import {CuratorRecord, Range, VaultView} from "../../src/types/Types.sol";

/// @notice Scenario S2: anchor coverage is lost, the grace period expires, accrual pauses, and restored coverage
/// clears the breach before rewards resume.
/// @custom:guarantee G-5
/// @custom:requirement R-COV-1 R-COV-2 R-COV-3 R-SBY-3
abstract contract BreachScenarioBase is Matrix {
    uint128 internal constant RATE = 1e12;
    uint128 internal constant COVERED_COMMITMENT = 3e17;
    uint128 internal constant UNCOVERED_COMMITMENT = 5e17;

    BallastStandby internal standby;
    uint256 internal vaultId;

    function setUp() public {
        _setUpMatrix(ConfigFixture.compressed(), 0);
        Range[] memory ranges = new Range[](1);
        ranges[0] = Range(-6000, 6000);
        vaultId = vaults.createVault(ranges, COVERED_COMMITMENT, 1000);
        uint128[] memory liquidities = new uint128[](1);
        liquidities[0] = 1e19;
        vaults.seed(vaultId, liquidities, type(uint128).max, type(uint128).max, address(this));

        standby = BallastStandby(address(vaults.standby()));
        quote.mint(ConfigFixture.SPONSOR, 1e24);
        vm.prank(ConfigFixture.SPONSOR);
        quote.approve(address(standby), type(uint256).max);
        vm.prank(ConfigFixture.SPONSOR);
        standby.fundStandby(1e15);
        vm.prank(ConfigFixture.SPONSOR);
        standby.setStandbyRate(RATE);
    }

    function test_SlowBleed_CoverageLossFlagsAfterGrace_PausesAndResumesAccrual() public {
        vaults.checkpoint(vaultId);
        uint40 start = uint40(vm.getBlockTimestamp());
        vaults.setCommitment(vaultId, UNCOVERED_COMMITMENT);

        vm.warp(start + 10);
        vm.expectEmit(true, false, false, true);
        emit IBallastEvents.CoverageLost(vaultId, start + 10 + 300);
        vaults.checkpoint(vaultId);
        assertEq(lens.vault(vaultId).breachSince, 0, "grace begins before breach");

        vm.warp(start + 10 + 300);
        vm.expectEmit(true, false, false, false);
        emit IBallastEvents.BreachFlagged(vaultId, 0, 0);
        vaults.checkpoint(vaultId);
        VaultView memory breached = lens.vault(vaultId);
        assertGt(breached.breachSince, 0);
        assertEq(lens.committedDepth(), 0, "breached vault is excluded from committed depth");
        CuratorRecord memory record = lens.vaultRecord(vaultId);
        assertEq(record.breachCount, 1);

        uint256 credited = standby.standbyInfo().totalCredited;
        vm.warp(vm.getBlockTimestamp() + 200);
        vaults.checkpoint(vaultId);
        assertEq(standby.standbyInfo().totalCredited, credited, "breach pauses rewards");

        vaults.setCommitment(vaultId, COVERED_COMMITMENT);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.expectEmit(true, false, false, false);
        emit IBallastEvents.BreachCleared(vaultId);
        vaults.checkpoint(vaultId);
        assertEq(lens.vault(vaultId).breachSince, 0);
        assertGt(lens.committedDepth(), 0);

        credited = standby.standbyInfo().totalCredited;
        vm.warp(vm.getBlockTimestamp() + 100);
        vaults.checkpoint(vaultId);
        assertGt(
            standby.standbyInfo().totalCredited, credited, "rewards resume after coverage returns"
        );
    }
}

contract BreachScenario_C0Before is BreachScenarioBase, C0Before {}

contract BreachScenario_C0After is BreachScenarioBase, C0After {}

contract BreachScenario_C1Before is BreachScenarioBase, C1Before {}

contract BreachScenario_C1After is BreachScenarioBase, C1After {}
