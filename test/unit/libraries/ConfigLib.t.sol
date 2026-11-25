// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ConfigLib} from "../../../src/libraries/ConfigLib.sol";
import {IBallastErrors} from "../../../src/interfaces/IBallastErrors.sol";
import {Config} from "../../../src/types/Types.sol";
import {ConfigFixture} from "../../utils/ConfigFixture.sol";

contract ConfigLibHarness {
    function validate(Config memory c) external pure {
        ConfigLib.validate(c);
    }
}

/// @custom:requirement R-CFG-1
contract ConfigLibTest is Test {
    ConfigLibHarness internal h = new ConfigLibHarness();

    function _ok(Config memory c) internal view {
        h.validate(c);
    }

    function _bad(Config memory c) internal {
        vm.expectRevert(IBallastErrors.InvalidConfig.selector);
        h.validate(c);
    }

    function test_Validate_AcceptsProdLikeConfig() public view {
        _ok(ConfigFixture.prodLike());
    }

    function test_RevertWhen_CurrencyIsNativeOrEqual() public {
        Config memory c = ConfigFixture.prodLike();
        c.collateral = Currency.wrap(address(0));
        _bad(c);
        c = ConfigFixture.prodLike();
        c.quote = Currency.wrap(address(0));
        _bad(c);
        c = ConfigFixture.prodLike();
        c.quote = c.collateral;
        _bad(c);
    }

    function test_RevertWhen_SponsorOrInitializerIsZero() public {
        Config memory c = ConfigFixture.prodLike();
        c.sponsor = address(0);
        _bad(c);
        c = ConfigFixture.prodLike();
        c.initializer = address(0);
        _bad(c);
    }

    function test_Fee_BoundsAndDynamicFlag() public {
        Config memory c = ConfigFixture.prodLike();
        c.fee = 0;
        _ok(c);
        c.fee = 1_000_000; // MAX_LP_FEE
        _ok(c);
        c.fee = 1_000_001;
        _bad(c);
        c.fee = 0x800000; // dynamic-fee flag
        _bad(c);
    }

    function test_TickSpacing_Bounds() public {
        Config memory c = ConfigFixture.prodLike();
        c.tickSpacing = 1;
        _ok(c);
        c.tickSpacing = type(int16).max;
        _ok(c);
        c.tickSpacing = 0;
        _bad(c);
        c.tickSpacing = -1;
        _bad(c);
        c.tickSpacing = int24(type(int16).max) + 1;
        _bad(c);
    }

    function test_BandBps_Bounds() public {
        Config memory c = ConfigFixture.prodLike();
        c.bandBps = 100;
        c.stressEnterBps = 50;
        c.stressExitBps = 25;
        _ok(c);
        c.bandBps = 2500;
        _ok(c);
        c.bandBps = 99;
        _bad(c);
        c.bandBps = 2501;
        _bad(c);
    }

    function test_StressThresholds_Ordering() public {
        Config memory c = ConfigFixture.prodLike(); // band 750
        c.stressEnterBps = 749;
        c.stressExitBps = 748;
        _ok(c);
        c.stressEnterBps = 750; // must be < bandBps
        _bad(c);
        c = ConfigFixture.prodLike();
        c.stressEnterBps = 50;
        c.stressExitBps = 49;
        _ok(c);
        c.stressEnterBps = 49; // must be >= 50
        c.stressExitBps = 10;
        _bad(c);
        c = ConfigFixture.prodLike();
        c.stressExitBps = c.stressEnterBps; // hysteresis requires exit < enter
        _bad(c);
    }

    function test_Windows_Bounds() public {
        Config memory c = ConfigFixture.prodLike();
        c.anchorWindow = 1 hours;
        c.shortWindow = 5 minutes;
        c.calmDuration = 5 minutes;
        c.observationCardinality = 61 + 5; // ceil(3600/60) + 1 = 61
        _ok(c);
        c.anchorWindow = 1 hours - 1;
        _bad(c);

        c = ConfigFixture.prodLike();
        c.shortWindow = 5 minutes;
        c.calmDuration = 1 hours;
        _ok(c);
        c.shortWindow = 5 minutes - 1;
        _bad(c);

        c = ConfigFixture.prodLike();
        c.shortWindow = c.anchorWindow - 1;
        c.calmDuration = c.shortWindow;
        _ok(c);
        c.shortWindow = c.anchorWindow; // must be strictly shorter
        c.calmDuration = c.shortWindow;
        _bad(c);

        c = ConfigFixture.prodLike();
        c.calmDuration = c.shortWindow;
        _ok(c);
        c.calmDuration = c.shortWindow - 1;
        _bad(c);
    }

    function test_Durations_UpperBounds() public {
        Config memory c = ConfigFixture.prodLike();
        c.maxStressLock = 7 days;
        _ok(c);
        c.maxStressLock = 7 days + 1;
        _bad(c);
        c = ConfigFixture.prodLike();
        c.exitNotice = 0; // allowed (tests)
        _ok(c);
        c.exitNotice = 3 days;
        _ok(c);
        c.exitNotice = 3 days + 1;
        _bad(c);
    }

    function test_ObservationInterval_AndDependentBounds() public {
        Config memory c = ConfigFixture.prodLike();
        c.observationInterval = 0;
        _bad(c);

        c = ConfigFixture.prodLike();
        c.rerangeGrace = c.observationInterval;
        _ok(c);
        c.rerangeGrace = c.observationInterval - 1;
        _bad(c);

        c = ConfigFixture.prodLike();
        c.maxAccrualInterval = c.observationInterval;
        _ok(c);
        c.maxAccrualInterval = c.observationInterval - 1;
        _bad(c);
    }

    function test_CuratorFeeCap_Bounds() public {
        Config memory c = ConfigFixture.prodLike();
        c.maxCuratorFeeBps = 5000;
        _ok(c);
        c.maxCuratorFeeBps = 5001;
        _bad(c);
    }

    function test_Cardinality_HardMinimum() public {
        Config memory c = ConfigFixture.prodLike(); // 86400 / 60 = 1440 exactly, so minimum 1441
        c.observationCardinality = 1441;
        _ok(c);
        c.observationCardinality = 1440;
        _bad(c);

        // Non-divisible: ceil(86401 / 60) + 1 = 1442
        c = ConfigFixture.prodLike();
        c.anchorWindow = 86_401;
        c.observationCardinality = 1442;
        _ok(c);
        c.observationCardinality = 1441;
        _bad(c);
    }

    function testFuzz_Validate_NeverAcceptsCardinalityBelowMinimum(
        uint32 anchor,
        uint32 interval,
        uint16 card
    ) public {
        anchor = uint32(bound(anchor, 1 hours, 30 days));
        interval = uint32(bound(interval, 1, 3600));
        Config memory c = ConfigFixture.prodLike();
        c.anchorWindow = anchor;
        c.observationInterval = interval;
        c.rerangeGrace = interval;
        c.maxAccrualInterval = interval;
        c.observationCardinality = card;
        uint256 minCard = (uint256(anchor) + interval - 1) / interval + 1;
        if (card >= minCard) {
            h.validate(c);
        } else {
            vm.expectRevert(IBallastErrors.InvalidConfig.selector);
            h.validate(c);
        }
    }
}
