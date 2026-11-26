// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import {IBallastPool} from "./IBallastPool.sol";
import {
    CuratorRecord,
    PositionView,
    Range,
    StandbyInfo,
    TicketView,
    VaultView
} from "../types/Types.sol";

/// @title IBallastHook
/// @notice Public surface of the Ballast hook. Behaviour is defined in docs/SPEC.md.
/// @dev The ERC-6909 surface (`balanceOf`, `transfer`, `approve`, `setOperator`, ...) is the vault share token,
/// id = vaultId. Shares are distinct from PoolManager claims. `totalSupply` is tracked by the hook.
interface IBallastHook is IBallastPool, IERC6909Claims {
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

    /// @notice Flags a vault whose coverage stayed below its commitment past `rerangeGrace`.
    function flagBreach(uint256 vaultId) external;

    // ─── Sponsor ───

    /// @notice Sponsor only. Pulls quote currency into the standby fund. Not withdrawable in v1 (ADR-021).
    function fundStandby(uint128 amount) external;

    /// @notice Sponsor only. `rate <= maxStandbyRate`.
    function setStandbyRate(uint128 rate) external;

    // ─── Views ───

    /// @notice Open ticket shares of a vault whose effective exit (`max(maturity, earliestUnlock)`) is within
    /// `horizon` seconds. Conservative: never below the exact figure (ADR-045).
    function exitingShares(uint256 vaultId, uint32 horizon) external view returns (uint256);

    function vaultCount() external view returns (uint256);
    function vault(uint256 vaultId) external view returns (VaultView memory);
    function positionsOf(uint256 vaultId) external view returns (PositionView[] memory);
    function ticket(uint256 ticketId) external view returns (TicketView memory);
    function record(uint256 vaultId) external view returns (CuratorRecord memory);
    function standbyInfo() external view returns (StandbyInfo memory);

    /// @notice Total supply of a vault's shares, including escrow and the burned minimum.
    function totalSupply(uint256 vaultId) external view returns (uint256);
}
