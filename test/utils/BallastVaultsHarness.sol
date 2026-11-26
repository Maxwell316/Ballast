// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BallastVaults} from "../../src/BallastVaults.sol";
import {IBallastHook} from "../../src/interfaces/IBallastHook.sol";
import {Config, CuratorRecord, Position} from "../../src/types/Types.sol";

/// @notice TEST-ONLY subclass of `BallastVaults` exposing the internal state through direct getters, so that the lens'
/// `extsload` decoding can be compared with the real values (a layout change breaks `LensLayout.t.sol`, ADR-050).
/// It adds no state-changing path and is never deployed.
contract BallastVaultsHarness is BallastVaults {
    constructor(IPoolManager pm, IBallastHook hook_, Config memory cfg)
        BallastVaults(pm, hook_, cfg)
    {}

    function vaultData(uint256 v) external view returns (VaultData memory) {
        return _vaults[v];
    }

    function positionsData(uint256 v) external view returns (Position[] memory) {
        return _positions[v];
    }

    function recordData(uint256 v) external view returns (CuratorRecord memory) {
        return _records[v];
    }

    function ticketData(uint256 id) external view returns (Ticket memory) {
        return _tickets[id];
    }

    function bucketData(uint256 v, uint256 i) external view returns (Bucket memory) {
        return _buckets[v][i];
    }

    function maturedData(uint256 v) external view returns (uint128) {
        return _maturedEscrow[v];
    }

    function vaultCountData() external view returns (uint256) {
        return _vaultCount;
    }

    function ticketCountData() external view returns (uint256) {
        return _ticketCount;
    }
}
