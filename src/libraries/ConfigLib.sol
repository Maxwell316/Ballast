// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IBallastErrors} from "../interfaces/IBallastErrors.sol";
import {Config} from "../types/Types.sol";

/// @title ConfigLib
/// @notice Validates the immutable hook `Config` against the bounds of SPEC §14.
/// @dev All bounds are named constants. Validation reverts with `InvalidConfig` on any violation.
library ConfigLib {
    uint16 internal constant MIN_BAND_BPS = 100;
    uint16 internal constant MAX_BAND_BPS = 2500;
    uint16 internal constant MIN_STRESS_ENTER_BPS = 50;
    uint32 internal constant MIN_ANCHOR_WINDOW = 1 hours;
    uint32 internal constant MIN_SHORT_WINDOW = 5 minutes;
    uint32 internal constant MAX_STRESS_LOCK_CAP = 7 days;
    uint32 internal constant MAX_EXIT_NOTICE_CAP = 3 days;
    uint16 internal constant MAX_CURATOR_FEE_CAP_BPS = 5000;

    /// @notice Reverts with `InvalidConfig` unless `c` satisfies every bound of SPEC §14 (R-CFG-1).
    /// @custom:requirement R-CFG-1
    function validate(Config memory c) internal pure {
        // Currencies: distinct, neither native (address zero).
        address collateral = Currency.unwrap(c.collateral);
        address quote = Currency.unwrap(c.quote);
        if (collateral == address(0) || quote == address(0) || collateral == quote) {
            revert IBallastErrors.InvalidConfig();
        }

        // Privileged-by-name addresses must exist.
        if (c.sponsor == address(0) || c.initializer == address(0)) {
            revert IBallastErrors.InvalidConfig();
        }

        // Pool key constraints: static fee within the PoolManager maximum (this also rejects the dynamic-fee flag,
        // which is larger than MAX_LP_FEE) and a tick spacing the PoolManager accepts.
        if (c.fee > LPFeeLibrary.MAX_LP_FEE) revert IBallastErrors.InvalidConfig();
        if (c.tickSpacing < TickMath.MIN_TICK_SPACING || c.tickSpacing > TickMath.MAX_TICK_SPACING)
        {
            revert IBallastErrors.InvalidConfig();
        }

        // Band and stress thresholds (bps).
        if (c.bandBps < MIN_BAND_BPS || c.bandBps > MAX_BAND_BPS) {
            revert IBallastErrors.InvalidConfig();
        }
        if (c.stressEnterBps < MIN_STRESS_ENTER_BPS || c.stressEnterBps >= c.bandBps) {
            revert IBallastErrors.InvalidConfig();
        }
        if (c.stressExitBps >= c.stressEnterBps) revert IBallastErrors.InvalidConfig();

        // Windows and durations (seconds).
        if (c.anchorWindow < MIN_ANCHOR_WINDOW) revert IBallastErrors.InvalidConfig();
        if (c.shortWindow < MIN_SHORT_WINDOW || c.shortWindow >= c.anchorWindow) {
            revert IBallastErrors.InvalidConfig();
        }
        if (c.calmDuration < c.shortWindow) revert IBallastErrors.InvalidConfig();
        if (c.maxStressLock > MAX_STRESS_LOCK_CAP) revert IBallastErrors.InvalidConfig();
        if (c.exitNotice > MAX_EXIT_NOTICE_CAP) revert IBallastErrors.InvalidConfig();
        if (c.observationInterval == 0) revert IBallastErrors.InvalidConfig();
        if (c.rerangeGrace < c.observationInterval) revert IBallastErrors.InvalidConfig();
        if (c.maxAccrualInterval < c.observationInterval) revert IBallastErrors.InvalidConfig();

        // Curator fee cap.
        if (c.maxCuratorFeeBps > MAX_CURATOR_FEE_CAP_BPS) revert IBallastErrors.InvalidConfig();

        // Oracle ring size: hard minimum ceil(anchorWindow / observationInterval) + 1 (R-ORC-5, R-ORC-7).
        // SAFETY: uint32 operands widened to uint256; the sum cannot overflow.
        uint256 minCardinality =
            (uint256(c.anchorWindow) + c.observationInterval - 1) / c.observationInterval + 1;
        if (c.observationCardinality < minCardinality) revert IBallastErrors.InvalidConfig();
    }
}
