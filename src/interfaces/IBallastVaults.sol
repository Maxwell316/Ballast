// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBallastErrors} from "./IBallastErrors.sol";
import {IBallastEvents} from "./IBallastEvents.sol";
import {Range} from "../types/Types.sol";

/// @title IBallastVaults
/// @notice Public surface of the custody contract (ADR-045). Behaviour is defined in docs/SPEC.md.
/// @dev The vault share token (ERC-6909, id = vaultId) is the separate `BallastShares` contract (`shareToken()`).
/// Shares are distinct from PoolManager claims. State reads go through `extsload`; the decoded views live in the lens.
interface IBallastVaults is IBallastErrors, IBallastEvents {
    // ─── Vault lifecycle ───

    /// @notice Creates an empty vault. The caller becomes its curator. Ranges are stored; no liquidity exists yet.
    function createVault(Range[] calldata ranges, uint128 commitment, uint16 curatorFeeBps)
        external
        returns (uint256 vaultId);

    /// @notice First deposit. Curator only. Mints INITIAL_SHARES to `receiver` and burns MINIMUM_SHARES.
    function seed(
        uint256 vaultId,
        uint128[] calldata liquidities,
        uint128 amount0Max,
        uint128 amount1Max,
        address receiver
    ) external returns (uint128 amount0, uint128 amount1);

    /// @notice Proportional deposit of `shares` into a seeded vault. CALM only.
    function deposit(
        uint256 vaultId,
        uint128 shares,
        uint128 amount0Max,
        uint128 amount1Max,
        address receiver
    ) external returns (uint128 amount0, uint128 amount1);

    /// @notice Escrows `shares` and creates a ticket owned by the caller. The receiver is chosen at claim time.
    function requestRedeem(uint256 vaultId, uint128 shares) external returns (uint256 ticketId);

    /// @notice Returns the escrowed shares of a ticket to its owner.
    function cancelRedeem(uint256 ticketId) external;

    /// @notice Redeems a matured ticket. Callable by the owner or an operator of the owner.
    function claimRedeem(uint256 ticketId, address receiver)
        external
        returns (uint128 amount0, uint128 amount1);

    /// @notice Curator only, CALM only. Atomically removes and re-adds liquidity in one unlock.
    function rerange(uint256 vaultId, Range[] calldata newRanges, uint128[] calldata liquidities)
        external;

    /// @notice Curator only, any state. Deploys idle balances into a position; never reduces liquidity.
    function deployIdle(uint256 vaultId, Range calldata range, uint128 liquidity) external;

    /// @notice Curator only. Increases apply immediately, decreases after `exitNotice`.
    function setCommitment(uint256 vaultId, uint128 newCommitment) external;

    /// @notice Curator only. Pays the curator's accrued fees.
    function claimCuratorFees(uint256 vaultId, address to)
        external
        returns (uint128 amount0, uint128 amount1);

    // ─── Permissionless maintenance ───

    /// @notice Accrues standby rewards and crystallizes trading fees for a vault.
    function checkpoint(uint256 vaultId) external;

    // ─── Reads ───

    /// @notice Reads `n` consecutive raw storage slots from `slot`. The lens decodes vault state with it (ADR-050).
    function extsload(bytes32 slot, uint256 n) external view returns (bytes32[] memory);
}
