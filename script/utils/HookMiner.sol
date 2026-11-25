// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title HookMiner
/// @notice Finds a CREATE2 salt whose resulting address carries exactly the requested hook permission bits.
/// @dev Our own minimal miner (v4-periphery no longer ships one; ADR-030). The 14 low address bits must equal
/// `flags & ALL_HOOK_MASK` exactly. Expected work is about 2^14 iterations; `MAX_LOOP` makes failure
/// probability negligible (about e^-30). For `forge script`, the deployer is the CREATE2 deployer proxy
/// (`CREATE2_FACTORY` in forge-std).
library HookMiner {
    /// @notice No salt within `MAX_LOOP` iterations produced the requested flags.
    error NoSaltFound();

    /// @dev Mask of the hook-permission bits in an address.
    uint160 internal constant FLAG_MASK = Hooks.ALL_HOOK_MASK;
    /// @dev Upper bound on iterations, so the search always terminates.
    uint256 internal constant MAX_LOOP = 500_000;

    /// @notice Finds a salt for `deployer` such that CREATE2 of `creationCode ++ constructorArgs` has bits `flags`.
    /// @param deployer The account that executes CREATE2.
    /// @param flags Desired permission bits (masked to the low 14 bits).
    /// @param creationCode `type(Hook).creationCode`.
    /// @param constructorArgs ABI-encoded constructor arguments.
    /// @return hookAddress The deterministic address.
    /// @return salt The salt to pass to CREATE2.
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        flags = flags & FLAG_MASK;
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i; i < MAX_LOOP; ++i) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (uint160(hookAddress) & FLAG_MASK == flags) return (hookAddress, salt);
        }
        revert NoSaltFound();
    }

    /// @notice The CREATE2 address of `deployer`, `salt` and init-code hash.
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))
            )
        );
    }
}
