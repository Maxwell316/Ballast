// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Config} from "../../src/types/Types.sol";

/// @dev Reference configurations for tests. `prodLike` mirrors the CLAUDE.md §6.10 defaults.
library ConfigFixture {
    address internal constant COLLATERAL = address(0xC0111A7E);
    address internal constant QUOTE = address(0x00C0FFEE);
    address internal constant SPONSOR = address(0x5B0505);
    address internal constant INITIALIZER = address(0x1217);

    function prodLike() internal pure returns (Config memory c) {
        c.collateral = Currency.wrap(COLLATERAL);
        c.quote = Currency.wrap(QUOTE);
        c.sponsor = SPONSOR;
        c.initializer = INITIALIZER;
        c.fee = 3000;
        c.tickSpacing = 60;
        c.bandBps = 750;
        c.stressEnterBps = 300;
        c.stressExitBps = 150;
        c.anchorWindow = 24 hours;
        c.shortWindow = 15 minutes;
        c.calmDuration = 1 hours;
        c.maxStressLock = 24 hours;
        c.exitNotice = 6 hours;
        c.rerangeGrace = 1 hours;
        c.maxAccrualInterval = 1 hours;
        c.maxCuratorFeeBps = 2000;
        c.observationInterval = 60;
        c.observationCardinality = 1585; // ceil(86400 / 60) + 1 = 1441 minimum; 1.1x margin
        c.maxStandbyRate = 1e12;
    }

    /// @dev Short windows for tests that sweep many snapshots quickly: 1 h anchor, 5 min short, 60 s interval.
    function compressed() internal pure returns (Config memory c) {
        c = prodLike();
        c.anchorWindow = 1 hours;
        c.shortWindow = 5 minutes;
        c.calmDuration = 10 minutes;
        c.maxStressLock = 1 hours;
        c.exitNotice = 10 minutes;
        c.rerangeGrace = 5 minutes;
        c.maxAccrualInterval = 5 minutes;
        c.observationCardinality = 67; // ceil(3600 / 60) + 1 = 61 minimum
    }
}
