// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EXIT_BUCKETS} from "../types/Constants.sol";

/// @title VaultsLayout
/// @notice Storage layout of `BallastVaults` as seen by the lens through `extsload` (ADR-050). Slot numbers and
/// field offsets are pinned by `test/unit/lens/LensLayout.t.sol`, which compares every decoded value with the vaults'
/// own state through a harness, so a layout change breaks the build. The reference table is `docs/storage-layout.md`.
/// @dev Mapping slots are `keccak256(abi.encode(key, slot))`; dynamic-array data starts at `keccak256(slot)`.
library VaultsLayout {
    uint256 internal constant SLOT_VAULTS = 0;
    uint256 internal constant SLOT_POSITIONS = 1;
    uint256 internal constant SLOT_RECORDS = 2;
    uint256 internal constant SLOT_TICKETS = 4;
    uint256 internal constant SLOT_BUCKETS = 5;
    uint256 internal constant SLOT_MATURED = 6;
    uint256 internal constant SLOT_VAULT_COUNT = 7;

    /// @dev Slots of one `VaultData`, one `CuratorRecord` and one `Ticket`.
    uint256 internal constant VAULT_SLOTS = 5;
    uint256 internal constant RECORD_SLOTS = 2;
    uint256 internal constant TICKET_SLOTS = 2;

    function mapSlot(uint256 key, uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    function vaultSlot(uint256 v) internal pure returns (bytes32) {
        return mapSlot(v, SLOT_VAULTS);
    }

    function positionsLengthSlot(uint256 v) internal pure returns (bytes32) {
        return mapSlot(v, SLOT_POSITIONS);
    }

    function positionsDataSlot(uint256 v) internal pure returns (bytes32) {
        return keccak256(abi.encode(positionsLengthSlot(v)));
    }

    function recordSlot(uint256 v) internal pure returns (bytes32) {
        return mapSlot(v, SLOT_RECORDS);
    }

    function ticketSlot(uint256 id) internal pure returns (bytes32) {
        return mapSlot(id, SLOT_TICKETS);
    }

    function bucketsSlot(uint256 v) internal pure returns (bytes32) {
        return mapSlot(v, SLOT_BUCKETS);
    }

    function maturedSlot(uint256 v) internal pure returns (bytes32) {
        return mapSlot(v, SLOT_MATURED);
    }

    // ─── Field decoding (offsets in bytes from the least-significant end of a slot) ───

    /// @dev Extracts `bytes_` bytes at byte offset `off` (from the right) of `word`.
    function field(bytes32 word, uint256 off, uint256 bytes_) internal pure returns (uint256) {
        return (uint256(word) >> (off * 8)) & ((uint256(1) << (bytes_ * 8)) - 1);
    }

    /// @dev Signed field: sign-extends a two's-complement value of `bytes_` bytes to int256.
    function sfield(bytes32 word, uint256 off, uint256 bytes_) internal pure returns (int256) {
        uint256 raw = field(word, off, bytes_);
        uint256 signBit = uint256(1) << (bytes_ * 8 - 1);
        return raw & signBit != 0 ? int256(raw) - int256(signBit << 1) : int256(raw);
    }

    function bucketCount() internal pure returns (uint256) {
        return EXIT_BUCKETS;
    }
}
