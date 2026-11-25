// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Observations} from "../../src/libraries/Observations.sol";

/// @dev Storage host for the `Observations` library, plus gas-measuring entry points. Test-only.
contract ObservationsHarness {
    Observations.Observation[] internal obs;
    Observations.State internal s;

    function initialize(uint40 time, int24 tick, uint16 cardinality) external {
        Observations.initialize(obs, s, time, tick, cardinality);
    }

    function update(uint40 nowTs, int24 preSwapTick, uint32 minInterval) external returns (bool) {
        return Observations.update(obs, s, nowTs, preSwapTick, minInterval);
    }

    function cumulativeNow(uint40 nowTs, int24 currentTick) external view returns (int56) {
        return Observations.cumulativeNow(s, nowTs, currentTick);
    }

    function cumulativeAt(uint40 nowTs, uint32 secondsAgo, int24 currentTick)
        external
        view
        returns (int56, bool)
    {
        return Observations.cumulativeAt(obs, s, nowTs, secondsAgo, currentTick);
    }

    function twapTick(uint40 nowTs, uint32 window, int24 currentTick)
        external
        view
        returns (int24, bool)
    {
        return Observations.twapTick(obs, s, nowTs, window, currentTick);
    }

    function isWarm(uint40 nowTs, uint32 window) external view returns (bool) {
        return Observations.isWarm(obs, s, nowTs, window);
    }

    function state() external view returns (Observations.State memory) {
        return s;
    }

    function length() external view returns (uint256) {
        return obs.length;
    }

    function at(uint256 i) external view returns (Observations.Observation memory) {
        return obs[i];
    }

    // ─── Gas measurement: internal gas of one library call (excludes the external call into the harness) ───

    function gasUpdate(uint40 nowTs, int24 preSwapTick, uint32 minInterval)
        external
        returns (uint256 used)
    {
        uint256 g = gasleft();
        Observations.update(obs, s, nowTs, preSwapTick, minInterval);
        used = g - gasleft();
    }

    function gasTwap(uint40 nowTs, uint32 window, int24 currentTick)
        external
        view
        returns (uint256 used)
    {
        uint256 g = gasleft();
        Observations.twapTick(obs, s, nowTs, window, currentTick);
        used = g - gasleft();
    }

    function gasCumulativeNow(uint40 nowTs, int24 currentTick)
        external
        view
        returns (uint256 used)
    {
        uint256 g = gasleft();
        Observations.cumulativeNow(s, nowTs, currentTick);
        used = g - gasleft();
    }
}
