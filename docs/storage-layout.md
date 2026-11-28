# Compiler Storage Layout

Generated from `forge inspect BallastVaults storage-layout --json` with Solidity 0.8.26, `via_ir = true`,
optimizer enabled with 200 runs. Regenerate after storage changes; the lens decodes `BallastVaults` storage
directly through `extsload`, so slot and packing changes must be reviewed against `src/periphery/BallastLens.sol`
and its `LensLayout` tests.

## BallastVaults

| Slot | Label | Type |
|---:|---|---|
| 0 | `_vaults` | `mapping(uint256 => VaultData)` |
| 1 | `_positions` | `mapping(uint256 => Position[])` |
| 2 | `_records` | `mapping(uint256 => CuratorRecord)` |
| 3 | `_lastEpisode` | `mapping(uint256 => uint40)` |
| 4 | `_tickets` | `mapping(uint256 => Ticket)` |
| 5 | `_buckets` | `mapping(uint256 => Bucket[16])` |
| 6 | `_maturedEscrow` | `mapping(uint256 => uint128)` |
| 7 | `_vaultCount` | `uint256` |
| 8 | `_ticketCount` | `uint256` |

The compiler packs the following members into the struct-relative storage words. Mapping and dynamic-array
contents are addressed by their Solidity storage hash rules and do not consume additional top-level slots.

### `VaultData` (five words)

| Relative slot | Members, in declaration order |
|---:|---|
| 0 | `curator: address`, `curatorFeeBps: uint16`, `positionCount: uint8`, `pendingCommitmentAt: uint40` |
| 1 | `commitment: uint128`, `pendingCommitment: uint128` |
| 2 | `idle0: uint128`, `idle1: uint128` |
| 3 | `owed0: uint128`, `owed1: uint128` |
| 4 | `lastCheckpoint: uint40`, `breachSince: uint40`, `coverageLostSince: uint40`, `lastDepthSample: uint128` |

### Other stored structs

| Type | Members |
|---|---|
| `Position` | `tickLower: int24`, `tickUpper: int24`, `liquidity: uint128` |
| `CuratorRecord` | `coveredSeconds: uint64`, `trackedSeconds: uint64`, `rerangeCount: uint32`, `breachCount: uint32`, `stressEpisodesHeld: uint32`, `depthSeconds: uint256` |
| `Ticket` | `owner: address`, `maturity: uint40`, `vaultId: uint16`, `shares: uint128`, `bucketEpoch: uint40` |
| `Bucket` | `epoch: uint40`, `shares: uint128` |

## Other state

`BallastHook` stores its observation ring and stress machine; `BallastStandby` stores the sponsor fund, rate,
credited total and depletion flag; `BallastShares` stores the inherited ERC-6909 ledger and its total supply
accounting. Their layouts are independent of the lens's vault-state decoder. For a full compiler layout, run
`forge inspect <ContractName> storage-layout --json` for each contract.

Immutables are embedded in runtime code and are not part of this table. Transient-storage guards and transaction
flags are also outside persistent storage.
