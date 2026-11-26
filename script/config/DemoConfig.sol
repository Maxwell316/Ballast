// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Config} from "../../src/types/Types.sol";

/// @title DemoConfig
/// @notice Compressed time windows for the public testnet deployment, where time cannot be warped (CLAUDE.md §12).
/// @dev DEMO VALUES ONLY. They are not recommended production parameters: the anchor window is the smallest the
/// config bounds allow (1 h) and the stress lock is 30 minutes. `ProdLike` values live in `test/utils/ConfigFixture.sol`.
library DemoConfig {
    /// @dev ticks per decade of raw price, log_{1.0001}(10) rounded.
    int256 internal constant TICKS_PER_DECADE = 23_027;

    function make(Currency collateral, Currency quote, address sponsor, address initializer)
        internal
        pure
        returns (Config memory c)
    {
        c.collateral = collateral;
        c.quote = quote;
        c.sponsor = sponsor;
        c.initializer = initializer;
        c.fee = 3000;
        c.tickSpacing = 60;
        c.bandBps = 750;
        c.stressEnterBps = 300;
        c.stressExitBps = 150;
        c.anchorWindow = 1 hours;
        c.shortWindow = 5 minutes;
        c.calmDuration = 10 minutes;
        c.maxStressLock = 30 minutes;
        c.exitNotice = 5 minutes;
        c.rerangeGrace = 5 minutes;
        c.maxAccrualInterval = 5 minutes;
        c.maxCuratorFeeBps = 2000;
        c.observationInterval = 60;
        c.observationCardinality = 67; // ceil(3600 / 60) + 1 = 61 minimum; about 1.1x
        c.maxStandbyRate = 1e12;
    }

    /// @notice Starting tick for a 1:1 human price, rounded toward zero to a multiple of `spacing`.
    /// @dev Raw price is token1 per token0. Collateral = token0: quote raw per collateral raw = 10^(qd - cd).
    function startTick(
        bool collateralIs0,
        uint8 collateralDecimals,
        uint8 quoteDecimals,
        int24 spacing
    ) internal pure returns (int24) {
        int256 e = collateralIs0
            ? int256(uint256(quoteDecimals)) - int256(uint256(collateralDecimals))
            : int256(uint256(collateralDecimals)) - int256(uint256(quoteDecimals));
        int256 tick = (e * TICKS_PER_DECADE / int256(spacing)) * int256(spacing);
        // SAFETY: decimals are at most 255 in a uint8, but the demo uses 18/6, so |tick| < 2^20.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(tick);
    }
}
