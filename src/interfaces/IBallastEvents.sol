// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IBallastEvents
/// @notice Every state change of the hook emits one of these events. Ids and addresses are indexed.
interface IBallastEvents {
    event VaultCreated(
        uint256 indexed vaultId, address indexed curator, uint128 commitment, uint16 curatorFeeBps
    );
    event Seeded(
        uint256 indexed vaultId,
        address indexed receiver,
        uint128 shares,
        uint128 amount0,
        uint128 amount1
    );
    event Deposited(
        uint256 indexed vaultId,
        address indexed depositor,
        address indexed receiver,
        uint128 shares,
        uint128 amount0,
        uint128 amount1
    );
    event RedeemRequested(
        uint256 indexed ticketId,
        uint256 indexed vaultId,
        address indexed owner,
        uint128 shares,
        uint40 maturity
    );
    event RedeemCancelled(uint256 indexed ticketId);
    event RedeemClaimed(
        uint256 indexed ticketId,
        uint256 indexed vaultId,
        address indexed receiver,
        uint128 amount0,
        uint128 amount1
    );
    event Reranged(
        uint256 indexed vaultId, uint8 positionCount, uint128 depthBefore, uint128 depthAfter
    );
    event IdleDeployed(
        uint256 indexed vaultId, int24 tickLower, int24 tickUpper, uint128 liquidity
    );
    event CommitmentChanged(
        uint256 indexed vaultId, uint128 newCommitment, bool pending, uint40 effectiveAt
    );
    event Checkpointed(
        uint256 indexed vaultId, uint128 depthSample, uint128 eligibleDepth, uint128 reward
    );
    event RewardCredited(uint256 indexed vaultId, uint128 toIdle, uint128 toCurator);
    event CuratorFeeClaimed(
        uint256 indexed vaultId, address indexed to, uint128 amount0, uint128 amount1
    );
    event BreachFlagged(uint256 indexed vaultId, uint128 depth, uint128 commitment);
    event BreachCleared(uint256 indexed vaultId);
    event StressEntered(int24 anchorTick, int24 shortTick, uint40 startedAt);
    event StressRecovering(uint40 at);
    event StressExited(uint40 at);
    event LockExpired(uint40 at);
    event StandbyFunded(address indexed sponsor, uint128 amount);
    event StandbyRateSet(uint128 rate);
    event StandbyDepleted();
}
