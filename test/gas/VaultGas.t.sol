// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "../utils/HookFixture.sol";
import {ConfigFixture} from "../utils/ConfigFixture.sol";
import {Range} from "../../src/types/Types.sol";

/// @notice Gas of the vault operations through the real hook, vaults, shares, standby and PoolManager, with a funded
/// standby and a nonzero rate (the expensive path). Each figure is printed and asserted against the budget of
/// docs/TESTING.md §7 (amended by ADR-057 after the split added external calls to the hook, the shares token and the
/// depth contract). Warm storage is not assumed: every operation is the first of its transaction.
contract VaultGasTest is HookFixture {
    uint256 internal v;

    function setUp() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
        Range[] memory r = new Range[](2);
        r[0] = Range(-6000, 6000);
        r[1] = Range(-1200, 1200);
        v = vaults.createVault(r, 1e17, 500);
        uint128[] memory l = new uint128[](2);
        l[0] = 5e18;
        l[1] = 2e18;
        vaults.seed(v, l, type(uint128).max, type(uint128).max, address(this));
        quote.mint(ConfigFixture.SPONSOR, 1e18);
        vm.startPrank(ConfigFixture.SPONSOR);
        quote.approve(address(vaults.standby()), type(uint256).max);
        vaults.standby().fundStandby(1e15);
        vaults.standby().setStandbyRate(1e9);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 200);
        _swap(true, 1e16);
        vm.warp(vm.getBlockTimestamp() + 100);
    }

    function test_Gas_Deposit_TwoPositions() public {
        uint256 g = gasleft();
        vaults.deposit(v, 1e17, type(uint128).max, type(uint128).max, address(this));
        uint256 used = g - gasleft();
        emit log_named_uint("deposit (2 positions)", used);
        assertLt(used, 650_000, "deposit budget (ADR-057)");
    }

    function test_Gas_RequestRedeem() public {
        uint256 g = gasleft();
        vaults.requestRedeem(v, 1e17);
        uint256 used = g - gasleft();
        emit log_named_uint("requestRedeem", used);
        assertLt(used, 200_000, "requestRedeem budget (ADR-057)");
    }

    function test_Gas_ClaimRedeem_TwoPositions() public {
        uint256 t = vaults.requestRedeem(v, 1e17);
        vm.warp(vm.getBlockTimestamp() + 600);
        uint256 g = gasleft();
        vaults.claimRedeem(t, address(this));
        uint256 used = g - gasleft();
        emit log_named_uint("claimRedeem (2 positions)", used);
        assertLt(used, 650_000, "claimRedeem budget (ADR-057)");
    }

    function test_Gas_Rerange_TwoToTwo() public {
        Range[] memory r = new Range[](2);
        r[0] = Range(-6000, 6000);
        r[1] = Range(-1800, 1800);
        uint128[] memory l = new uint128[](2);
        l[0] = 4e18;
        l[1] = 1e18;
        uint256 g = gasleft();
        vaults.rerange(v, r, l);
        uint256 used = g - gasleft();
        emit log_named_uint("rerange (2 -> 2)", used);
        assertLt(used, 800_000, "rerange budget (ADR-057)");
    }

    function test_Gas_Checkpoint() public {
        uint256 g = gasleft();
        vaults.checkpoint(v);
        uint256 used = g - gasleft();
        emit log_named_uint("checkpoint (2 positions, rate set)", used);
        assertLt(used, 500_000, "checkpoint budget (ADR-057)");
    }

    function test_Gas_SetCommitment() public {
        uint256 g = gasleft();
        vaults.setCommitment(v, 2e17);
        uint256 used = g - gasleft();
        emit log_named_uint("setCommitment", used);
        assertLt(used, 500_000, "setCommitment budget (ADR-057)");
    }

    function test_Gas_Lens_CommittedAndLiveDepth_SixteenVaultsFullPositions() public {
        // 15 more vaults, each with 8 positions: the worst case the views are bounded by.
        for (uint256 i; i < 15; ++i) {
            Range[] memory r = new Range[](8);
            uint128[] memory l = new uint128[](8);
            for (uint256 j; j < 8; ++j) {
                // forge-lint: disable-next-line(unsafe-typecast)
                r[j] = Range(-int24(int256(600 + 60 * j)), int24(int256(600 + 60 * j)));
                l[j] = 1e16;
            }
            uint256 id = vaults.createVault(r, 0, 0);
            vaults.seed(id, l, type(uint128).max, type(uint128).max, address(this));
        }
        uint256 g = gasleft();
        lens.committedDepth();
        uint256 c = g - gasleft();
        g = gasleft();
        lens.liveDepth(750, 600);
        uint256 l2 = g - gasleft();
        emit log_named_uint("committedDepth (16 vaults x 8 positions)", c);
        emit log_named_uint("liveDepth (16 vaults x 8 positions)", l2);
        assertLt(c, 30_000_000, "view must fit comfortably in a block-gas-limit eth_call");
        assertLt(l2, 30_000_000);
    }
}
