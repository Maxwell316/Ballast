// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "../../utils/HookFixture.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {BallastVaults} from "../../../src/BallastVaults.sol";
import {
    CuratorRecord,
    Position,
    PositionView,
    Range,
    TicketView,
    VaultView
} from "../../../src/types/Types.sol";

/// @notice The lens decodes the vaults' storage through `extsload`. This test compares every decoded field with the
/// vaults' own state (read through the harness), after each step of a multi-vault lifecycle, so any storage-layout
/// change breaks the build (ADR-050).
/// @custom:requirement R-VIEW-4
contract LensLayoutTest is HookFixture {
    function setUp() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
    }

    function _assertSame(uint256 v) internal view {
        BallastVaults.VaultData memory d = vaults.vaultData(v);
        VaultView memory a = lens.vault(v);
        assertEq(a.curator, d.curator, "curator");
        assertEq(a.curatorFeeBps, d.curatorFeeBps, "feeBps");
        assertEq(a.commitment, d.commitment, "commitment");
        assertEq(a.pendingCommitment, d.pendingCommitment, "pendingCommitment");
        assertEq(a.pendingCommitmentAt, d.pendingCommitmentAt, "pendingAt");
        assertEq(a.totalShares, vaults.shareToken().totalSupply(v), "totalShares");
        assertEq(a.idle0, d.idle0, "idle0");
        assertEq(a.idle1, d.idle1, "idle1");
        assertEq(a.curatorOwed0, d.owed0, "owed0");
        assertEq(a.curatorOwed1, d.owed1, "owed1");
        assertEq(a.lastCheckpoint, d.lastCheckpoint, "lastCheckpoint");
        assertEq(a.breachSince, d.breachSince, "breachSince");
        assertEq(a.positionCount, d.positionCount, "positionCount");

        Position[] memory ps = vaults.positionsData(v);
        PositionView[] memory lp = lens.positionsOf(v);
        assertEq(lp.length, ps.length, "positions length");
        for (uint256 i; i < ps.length; ++i) {
            assertEq(lp[i].tickLower, ps[i].tickLower, "tickLower");
            assertEq(lp[i].tickUpper, ps[i].tickUpper, "tickUpper");
            assertEq(lp[i].liquidity, ps[i].liquidity, "liquidity");
        }

        CuratorRecord memory r = vaults.recordData(v);
        CuratorRecord memory lr = lens.vaultRecord(v);
        assertEq(lr.coveredSeconds, r.coveredSeconds, "covered");
        assertEq(lr.trackedSeconds, r.trackedSeconds, "tracked");
        assertEq(lr.rerangeCount, r.rerangeCount, "reranges");
        assertEq(lr.breachCount, r.breachCount, "breaches");
        assertEq(lr.stressEpisodesHeld, r.stressEpisodesHeld, "episodes");
        assertEq(lr.depthSeconds, r.depthSeconds, "depthSeconds");

        // Exit buckets: the lens' count with a horizon past every maturity equals the vault's matured pool plus
        // every bucket.
        uint256 sum = vaults.maturedData(v);
        for (uint256 i; i < 16; ++i) {
            sum += vaults.bucketData(v, i).shares;
        }
        assertEq(lens.exitingShares(v, 1 days), sum, "exiting shares");
    }

    function _assertTicket(uint256 id) internal view {
        BallastVaults.Ticket memory t = vaults.ticketData(id);
        TicketView memory lt = lens.ticket(id);
        assertEq(lt.vaultId, t.vaultId, "ticket vault");
        assertEq(lt.owner, t.owner, "ticket owner");
        assertEq(lt.shares, t.shares, "ticket shares");
        assertEq(lt.maturity, t.maturity, "ticket maturity");
    }

    function _assertAll() internal view {
        uint256 n = vaults.vaultCountData();
        assertEq(lens.vaultCount(), n);
        for (uint256 v = 1; v <= n; ++v) {
            _assertSame(v);
        }
        for (uint256 id = 1; id <= vaults.ticketCountData(); ++id) {
            _assertTicket(id);
        }
    }

    function test_LensDecodesVaultsStorage_AcrossALifecycle() public {
        _assertAll();
        uint256 v1 = _provide(-6000, 6000, 1e19);
        _assertAll();

        Range[] memory r = new Range[](2);
        r[0] = Range(-1200, 1200);
        r[1] = Range(-3000, 600);
        uint256 v2 = vaults.createVault(r, 5e16, 750);
        _assertAll();
        uint128[] memory l = new uint128[](2);
        l[0] = 3e18;
        l[1] = 2e18;
        vaults.seed(v2, l, type(uint128).max, type(uint128).max, address(this));
        _assertAll();

        vm.warp(vm.getBlockTimestamp() + 200);
        _swap(true, 2e16);
        _swap(false, 1e5);
        vm.warp(vm.getBlockTimestamp() + 200);
        vaults.deposit(v2, 1e17, type(uint128).max, type(uint128).max, address(0xABCD));
        _assertAll();

        vm.warp(vm.getBlockTimestamp() + 100);
        uint256 t1 = vaults.requestRedeem(v1, 1e16);
        vm.warp(vm.getBlockTimestamp() + 90);
        uint256 t2 = vaults.requestRedeem(v2, 2e16);
        vm.warp(vm.getBlockTimestamp() + 1000);
        uint256 t3 = vaults.requestRedeem(v2, 3e16);
        assertEq(t3, 3);
        _assertAll();

        vaults.setCommitment(v2, 1e16); // pending decrease
        _assertAll();
        vaults.cancelRedeem(t2);
        _assertAll();
        vaults.claimRedeem(t1, address(this));
        _assertAll();
        vaults.claimCuratorFees(v2, address(this));
        _assertAll();
    }
}
