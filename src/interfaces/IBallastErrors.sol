// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IBallastErrors
/// @notice Custom errors of the Ballast hook. No revert strings are used anywhere.
interface IBallastErrors {
    /// @notice The hook was constructed with an address that has no code (ADR-050).
    error VaultsNotDeployed(address vaults);
    /// @notice The vaults' immutable hook address or config hash does not match this hook (ADR-050, T20).
    error VaultsBindingMismatch();

    error NotCurator(address caller);
    error NotSponsor(address caller);
    error NotVaults(address caller);
    error PoolInitializerOnly(address caller);
    error PoolAlreadyBound();
    /// @notice A pool-dependent call was made before `beforeInitialize` bound the pool.
    error PoolNotBound();
    error InvalidPoolKey();
    error DynamicFeeUnsupported();
    error NativeCurrencyUnsupported();
    /// @notice The `Config` violates a bound of SPEC §14 (R-CFG-1).
    error InvalidConfig();
    error ExternalLiquidityForbidden();
    error TooManyVaults();
    error TooManyPositions();
    error InvalidRange(int24 lower, int24 upper);
    error DuplicateRange();
    error VaultNotSeeded();
    error VaultAlreadySeeded();
    error StressLockActive(uint40 until);
    error NotCalm();
    error SwapInSameTransaction();
    error VaultOpInSameTransaction();
    error Reentrancy();
    error CoverageBelowCommitment(uint128 depth, uint128 commitment);
    error TicketNotMature(uint40 maturity);
    error NotTicketOwnerOrOperator();
    error SlippageExceeded();
    error ZeroShares();
    error InsufficientIdle();
    error StandbyRateTooHigh();
    error GraceNotExpired(uint40 until);
    error VaultNotInBreach();
    error UnknownVault(uint256 vaultId);
    error UnknownTicket(uint256 ticketId);
    error InvalidLiquidities();
    error InvalidReceiver();
    error InvalidCuratorFee(uint16 feeBps);
    error AlreadyInBreach();
    error SharesExceedBalance();
}
