// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Transient
/// @notice Minimal EIP-1153 helpers for the per-transaction flags of the hook (D-9, R-TX-1..3). Solidity 0.8.26 has no
/// `transient` keyword for state variables, so the opcodes are used directly in two tiny, audited-by-inspection
/// functions. Transient storage is cleared by the EVM at the end of every transaction, so a flag set here can never
/// outlive the transaction that set it.
/// @dev Slots are `keccak256(label)`, so they cannot collide with Solidity's sequential storage layout or with each
/// other. Requires `evm_version = "cancun"` and a chain with EIP-1153 (Unichain Sepolia: verified in docs/VERIFICATION.md).
library Transient {
    /// @dev Set by `beforeSwap`; read by vault operations (R-TX-2).
    bytes32 internal constant SWAPPED = keccak256("ballast.transient.swapped");
    /// @dev Set by vault operations; read by `beforeSwap` (R-TX-1).
    bytes32 internal constant VAULT_OP = keccak256("ballast.transient.vaultOp");
    /// @dev Reentrancy lock (R-TX-3).
    bytes32 internal constant LOCK = keccak256("ballast.transient.lock");

    /// @notice Reads a flag from transient storage.
    function get(bytes32 slot) internal view returns (bool v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    /// @notice Writes a flag to transient storage.
    function set(bytes32 slot, bool v) internal {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }
}
