// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "../../utils/HookFixture.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";
import {BallastStandby} from "../../../src/BallastStandby.sol";
import {RewardMath} from "../../../src/libraries/RewardMath.sol";
import {Range} from "../../../src/types/Types.sol";

/// @notice Standby accrual pays on the smallest of the interval's depth samples (R-SBY-3, ADR-025): when the market
/// eats into a narrow vault, the reward follows the live depth, not the anchor-based depth or the commitment.
/// @custom:requirement R-SBY-3
/// @custom:guarantee G-5
contract StandbySamplingTest is HookFixture {
    uint128 internal constant RATE = 1e12;
    uint128 internal constant COMMITMENT = 3e17;
    uint16 internal constant BAND_BPS = 750;

    BallastStandby internal standby;
    uint256 internal v;

    function setUp() public {
        _setUpDefault(true, ConfigFixture.compressed(), 0);
        standby = BallastStandby(address(vaults.standby()));
        Range[] memory r = new Range[](1);
        r[0] = Range(-1200, 1200);
        v = vaults.createVault(r, COMMITMENT, 0);
        uint128[] memory l = new uint128[](1);
        l[0] = 2e19;
        vaults.seed(v, l, type(uint128).max, type(uint128).max, address(this));
        quote.mint(ConfigFixture.SPONSOR, 1e24);
        vm.startPrank(ConfigFixture.SPONSOR);
        quote.approve(address(standby), type(uint256).max);
        standby.fundStandby(1e18);
        standby.setStandbyRate(RATE);
        vm.stopPrank();
    }

    function test_Accrual_UsesTheSmallestSample_WhenLiveDepthFalls() public {
        vaults.checkpoint(v); // first sample: full depth at the start of the interval
        _swap(true, 11e17); // sell collateral into the vault, pushing the tick down toward -1000
        assertLt(_tick(), -500, "the market moved into the band");
        vm.warp(vm.getBlockTimestamp() + 100);

        uint256 expectedDepth = lens.poolAbsorbable(BAND_BPS);
        uint256 anchorDepth = lens.vaultDepth(v);
        if (anchorDepth < expectedDepth) expectedDepth = anchorDepth;
        if (COMMITMENT < expectedDepth) expectedDepth = COMMITMENT;
        assertLt(expectedDepth, COMMITMENT, "the sample is the binding one, not the commitment");

        uint256 before_ = lens.vault(v).idle1;
        vaults.checkpoint(v);
        uint256 paid = lens.vault(v).idle1 - before_; // zero curator fee: everything goes to idle
        assertEq(
            paid,
            RewardMath.accrue(uint128(expectedDepth), RATE, 100),
            "reward follows the smallest sample"
        );
    }
}
