# Ballast Contract Reference

**Status:** Draft v0.1 · The signatures below are the intended public surface. Implementers MAY refine types and packing, but any change to names, access control, units or semantics requires an ADR ([DECISIONS](DECISIONS.md)). Behaviour is defined in [SPEC](SPEC.md); formulas in [MATH](MATH.md).

---

## 1. Overview

| Contract | Path | Kind | Purpose |
|---|---|---|---|
| `BallastHook` | `src/BallastHook.sol` | Hook, shares ledger | Hook callbacks, vault lifecycle, stress machine, standby accounting, custody through the PoolManager |
| `BallastLens` | `src/periphery/BallastLens.sol` | Read-only | Depth and status views implementing `IBallastDepthOracle` |
| `SupplyCapAdvisor` | `src/periphery/SupplyCapAdvisor.sol` | Read-only | Reference conversion of depth into a suggested supply cap |

Inheritance for `BallastHook`: `BaseHook` (v4-periphery), `IBallastHook`, an ERC-6909 implementation for vault shares, `IUnlockCallback` (through the base or directly). **VERIFY** the exact base contract API in the pinned `lib/v4-periphery`.

Compiler: Solidity 0.8.26, `evm_version = cancun`. No upgradeability, no owner, no delegatecall, no selfdestruct.

---

## 2. Shared types (`src/types/Types.sol`)

```solidity
struct Range { int24 tickLower; int24 tickUpper; }

enum LockState { CALM, STRESS, RECOVERING }

struct Config {
    Currency collateral;
    Currency quote;
    address  sponsor;
    uint16   bandBps;
    uint16   stressEnterBps;
    uint16   stressExitBps;
    uint32   anchorWindow;
    uint32   shortWindow;
    uint32   calmDuration;
    uint32   maxStressLock;
    uint32   exitNotice;
    uint32   rerangeGrace;
    uint32   maxAccrualInterval;
    uint16   maxCuratorFeeBps;
    uint32   observationInterval;
    uint16   observationCardinality;
    uint128  maxStandbyRate;
}

struct VaultView {
    address curator;
    uint16  curatorFeeBps;
    uint128 commitment;
    uint128 pendingCommitment;
    uint40  pendingCommitmentAt;
    uint128 totalShares;          // includes escrowed and burned minimum
    uint128 idle0;
    uint128 idle1;
    uint128 curatorOwed0;
    uint128 curatorOwed1;
    uint40  lastCheckpoint;
    uint40  breachSince;          // 0 when covered
    uint8   positionCount;
}

struct PositionView { int24 tickLower; int24 tickUpper; uint128 liquidity; }

struct TicketView { uint256 vaultId; address owner; address receiver; uint128 shares; uint40 maturity; }

struct CuratorRecord {
    uint64  coveredSeconds;
    uint64  trackedSeconds;
    uint32  rerangeCount;
    uint32  breachCount;
    uint32  stressEpisodesHeld;
    uint256 depthSeconds;
}

struct StressInfo {
    LockState state;
    bool      oracleWarm;
    bool      lockActive;
    uint40    stressStartedAt;
    uint40    lockedUntil;          // 0 if lock inactive
    int24     anchorTick;
    int24     shortTick;
}

struct StandbyInfo { uint128 fundBalance; uint128 rate; uint256 totalCredited; }
```

Constants: `MAX_VAULTS = 16`, `MAX_POSITIONS = 8`, `MINIMUM_SHARES = 1e3`, `INITIAL_SHARES = 1e18`, `RATE_SCALE = 1e18`.

---

## 3. `IBallastHook`

### 3.1 Vault lifecycle (state-changing)

```solidity
/// Creates an empty vault. Caller is the curator. Ranges are stored, no liquidity yet.
function createVault(Range[] calldata ranges, uint128 commitment, uint16 curatorFeeBps)
    external returns (uint256 vaultId);

/// First deposit for a vault. Curator supplies per-position liquidity; mints INITIAL_SHARES
/// to `receiver` and burns MINIMUM_SHARES to address(0). Reverts if the vault already has supply.
function seed(
    uint256 vaultId, uint128[] calldata liquidities,
    uint128 amount0Max, uint128 amount1Max, address receiver
) external returns (uint128 amount0, uint128 amount1);

/// Proportional deposit of `shares` into a seeded vault.
function deposit(
    uint256 vaultId, uint128 shares,
    uint128 amount0Max, uint128 amount1Max, address receiver
) external returns (uint128 amount0, uint128 amount1);

function requestRedeem(uint256 vaultId, uint128 shares, address receiver)
    external returns (uint256 ticketId);

function cancelRedeem(uint256 ticketId) external;

function claimRedeem(uint256 ticketId)
    external returns (uint128 amount0, uint128 amount1);

/// Curator only. CALM only. Atomic remove-and-re-add in one unlock.
function rerange(uint256 vaultId, Range[] calldata newRanges, uint128[] calldata liquidities) external;

/// Curator only. Any state. Deploys idle balances; never reduces liquidity.
function deployIdle(uint256 vaultId, Range calldata range, uint128 liquidity) external;

/// Curator only. Increases immediate, decreases after exitNotice.
function setCommitment(uint256 vaultId, uint128 newCommitment) external;

/// Curator only.
function claimCuratorFees(uint256 vaultId, address to) external returns (uint128 amount0, uint128 amount1);
```

| Function | Access | Allowed states | Same-tx guard | Rounding / notes |
|---|---|---|---|---|
| `createVault` | anyone | all | none | Reverts per R-VLT-1 |
| `seed` | anyone (first depositor, normally the curator) | CALM | `VAULT_OP` | Pays PoolManager deltas rounded up |
| `deposit` | anyone | CALM | `VAULT_OP` | `ceilDiv` on liquidity and idle slices |
| `requestRedeem` | share holder | all | none | Escrows shares |
| `cancelRedeem` | ticket owner | all | none | Returns shares |
| `claimRedeem` | ticket owner or approved | CALM or lock expired | `VAULT_OP` | `floorDiv` on liquidity and idle slices |
| `rerange` | curator | CALM | `VAULT_OP` | Coverage check after; accrual uses min(before, after) |
| `deployIdle` | curator | all | `VAULT_OP` | Idle only |
| `setCommitment` | curator | all | none | Pending decrease |
| `claimCuratorFees` | curator | all | none | Pays `curatorOwed` only |

### 3.2 Permissionless maintenance

```solidity
function checkpoint(uint256 vaultId) external;           // accrue standby, crystallize fees
function flagBreach(uint256 vaultId) external;           // after rerangeGrace; stops accrual
function pokeStress() external;                          // evaluates the stress machine
```

### 3.3 Sponsor functions

```solidity
function fundStandby(uint128 amount) external;           // sponsor only; pulls quote currency
function setStandbyRate(uint128 rate) external;          // sponsor only; rate <= maxStandbyRate
```

### 3.4 Views

```solidity
function config() external view returns (Config memory);
function poolId() external view returns (PoolId);
function collateralIsCurrency0() external view returns (bool);
function vaultCount() external view returns (uint256);
function vault(uint256 vaultId) external view returns (VaultView memory);
function positionsOf(uint256 vaultId) external view returns (PositionView[] memory);
function ticket(uint256 ticketId) external view returns (TicketView memory);
function record(uint256 vaultId) external view returns (CuratorRecord memory);
function stressInfo() external view returns (StressInfo memory);
function standbyInfo() external view returns (StandbyInfo memory);
function previewDeposit(uint256 vaultId, uint128 shares) external view returns (uint128 amount0, uint128 amount1);
function previewRedeem(uint256 vaultId, uint128 shares) external view returns (uint128 amount0, uint128 amount1);
function twapTick(uint32 window) external view returns (int24 tick, bool warm);
```

`previewDeposit` and `previewRedeem` are estimates: the PoolManager's rounding is authoritative at execution time.

### 3.5 Shares (ERC-6909 surface)

`balanceOf(owner, vaultId)`, `allowance`, `isOperator`, `transfer`, `transferFrom`, `approve`, `setOperator`, `totalSupply(vaultId)`. Escrowed shares are held by the hook and are not transferable by their former owner. **VERIFY** whether to inherit v4-core's ERC-6909 or another implementation, and whether `totalSupply` needs a custom extension.

### 3.6 Hook callbacks

```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory);
// beforeInitialize, afterInitialize, beforeAddLiquidity, beforeRemoveLiquidity, beforeSwap: true. All else false.

function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96) internal override returns (bytes4);
function _afterInitialize(address, PoolKey calldata, uint160, int24 tick) internal override returns (bytes4);
function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) internal pure override returns (bytes4); // always reverts
function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) internal pure override returns (bytes4); // always reverts
function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
    internal override returns (bytes4, BeforeSwapDelta, uint24);  // oracle write, stress evaluation, SWAPPED flag
```

Names and parameter structs depend on the pinned periphery version. **VERIFY.** The `beforeSwap` implementation MUST return a zero `BeforeSwapDelta` and a zero fee override.

### 3.7 Unlock plumbing

```solidity
enum Action { SEED, DEPOSIT, REDEEM, RERANGE, DEPLOY_IDLE, CHECKPOINT, FUND }

function unlockCallback(bytes calldata data) external returns (bytes memory); // only PoolManager
```

Each public function ABI-encodes `(Action, params)` into one `unlock` call. The callback dispatches to an internal handler that performs all `modifyLiquidity`, `settle`, `take`, `mint` and `burn` calls and returns packed results.

---

## 4. Events and errors

### 4.1 Events (`IBallastEvents`)

```solidity
event VaultCreated(uint256 indexed vaultId, address indexed curator, uint128 commitment, uint16 curatorFeeBps);
event Seeded(uint256 indexed vaultId, address indexed receiver, uint128 shares, uint128 amount0, uint128 amount1);
event Deposited(uint256 indexed vaultId, address indexed depositor, address indexed receiver, uint128 shares, uint128 amount0, uint128 amount1);
event RedeemRequested(uint256 indexed ticketId, uint256 indexed vaultId, address indexed owner, uint128 shares, uint40 maturity);
event RedeemCancelled(uint256 indexed ticketId);
event RedeemClaimed(uint256 indexed ticketId, uint256 indexed vaultId, address indexed receiver, uint128 amount0, uint128 amount1);
event Reranged(uint256 indexed vaultId, uint8 positionCount, uint128 depthBefore, uint128 depthAfter);
event IdleDeployed(uint256 indexed vaultId, int24 tickLower, int24 tickUpper, uint128 liquidity);
event CommitmentChanged(uint256 indexed vaultId, uint128 newCommitment, bool pending, uint40 effectiveAt);
event Checkpointed(uint256 indexed vaultId, uint128 depthSample, uint128 eligibleDepth, uint128 reward);
event RewardCredited(uint256 indexed vaultId, uint128 toIdle, uint128 toCurator);
event CuratorFeeClaimed(uint256 indexed vaultId, address indexed to, uint128 amount0, uint128 amount1);
event BreachFlagged(uint256 indexed vaultId, uint128 depth, uint128 commitment);
event BreachCleared(uint256 indexed vaultId);
event StressEntered(int24 anchorTick, int24 shortTick, uint40 startedAt);
event StressRecovering(uint40 at);
event StressExited(uint40 at);
event LockExpired(uint40 at);
event StandbyFunded(address indexed sponsor, uint128 amount);
event StandbyRateSet(uint128 rate);
event StandbyDepleted();
```

### 4.2 Errors (`IBallastErrors`)

```solidity
error NotPoolManager();            error NotCurator(address caller);       error NotSponsor(address caller);
error PoolAlreadyBound();          error InvalidPoolKey();                 error DynamicFeeUnsupported();
error NativeCurrencyUnsupported(); error InvalidConfig();                  error ExternalLiquidityForbidden();
error TooManyVaults();             error TooManyPositions();               error InvalidRange(int24 lower, int24 upper);
error DuplicateRange();            error VaultNotSeeded();                 error VaultAlreadySeeded();
error StressLockActive(uint40 until);                                      error NotCalm();
error SwapInSameTransaction();     error VaultOpInSameTransaction();       error Reentrancy();
error CoverageBelowCommitment(uint128 depth, uint128 commitment);
error TicketNotMature(uint40 maturity);                                    error NotTicketOwner();
error SlippageExceeded();          error ZeroShares();                     error InsufficientIdle();
error StandbyRateTooHigh();        error GraceNotExpired(uint40 until);    error VaultNotInBreach();
```

---

## 5. `BallastLens` and `IBallastDepthOracle`

```solidity
interface IBallastDepthOracle {
    function committedDepth() external view returns (uint256 collateralAmount);
    function liveDepth(uint16 impactBps, uint32 horizon) external view returns (uint256 collateralAmount);
    function lockState() external view returns (LockState state, uint40 lockedUntil);
    function vaultRecord(uint256 vaultId) external view returns (CuratorRecord memory);
    function vaultStatus(uint256 vaultId) external view returns (uint128 depth, uint128 commitment, bool inBreach);
}
```

`BallastLens(IBallastHook hook)` is stateless apart from the hook address. It reads vault, position and ticket data through the hook's views and the PoolManager through `StateLibrary`, and computes depth with `DepthMath`. All loops are bounded (§R-VIEW-4). It exposes two extra views:

```solidity
function vaultDepth(uint256 vaultId) external view returns (uint256 committed);          // anchor band, this vault
function poolAbsorbable(uint16 impactBps) external view returns (uint256 collateralAmount); // spot band, all liquidity, no exit netting
```

## 6. `SupplyCapAdvisor`

```solidity
constructor(IBallastDepthOracle oracle);
function suggestedCap(uint256 multiplierWad, uint16 impactBps, uint32 horizon) external view returns (uint256);
// = multiplierWad * oracle.liveDepth(impactBps, horizon) / 1e18, rounded down
```

Reference only. It demonstrates how a risk module could size a cap from committed depth (the public Chaos Labs methodology uses a 2× multiplier). It holds no funds and has no side effects.

---

## 7. Libraries

```solidity
library Observations {
    struct Observation { uint32 timestamp; int56 tickCumulative; bool initialized; }
    struct State { uint16 index; uint16 cardinality; }
    function initialize(Observation[] storage self, uint32 time, int24 tick) internal;
    function write(Observation[] storage self, State storage s, uint32 time, int24 preSwapTick, uint32 minInterval) internal returns (bool wrote);
    function cumulativeAt(Observation[] storage self, State storage s, uint32 nowTs, uint32 secondsAgo, int24 currentTick) internal view returns (int56 cumulative, bool warm);
    function twapTick(Observation[] storage self, State storage s, uint32 nowTs, uint32 window, int24 currentTick) internal view returns (int24 tick, bool warm);
}

library BandMath {
    function bpsToTicksDown(uint16 bps) internal pure returns (uint24);      // price factor 1/(1-bps), conservative
    function bpsToTicksNearest(uint16 bps) internal pure returns (uint24);   // used for stress thresholds
    function bandEdges(int24 anchorTick, bool collateralIs0, uint24 bandTicks) internal pure returns (int24 nearTick, int24 farTick);
}

library DepthMath {
    function absorbable(bool collateralIs0, int24 tickLower, int24 tickUpper, uint128 liquidity, int24 nearTick, int24 farTick) internal pure returns (uint256);
    function liveAbsorbable(bool collateralIs0, int24 tickLower, int24 tickUpper, uint128 liquidity, uint160 sqrtSpotX96, int24 farTick) internal pure returns (uint256);
}

library StressMachine {
    struct Ctx { uint32 nowTs; uint32 stressStartedAt; uint32 belowExitSince; uint32 enterTicks; uint32 exitTicks; uint32 calmDuration; uint32 maxStressLock; bool rearmBlocked; }
    function next(LockState s, int256 dev, Ctx memory c) internal pure returns (LockState ns, Ctx memory nc, bool emittedLockExpiry);
    function lockActive(LockState s, Ctx memory c) internal pure returns (bool);
}

library VaultMath {
    function ceilShare(uint256 amount, uint256 shares, uint256 supply) internal pure returns (uint256);
    function floorShare(uint256 amount, uint256 shares, uint256 supply) internal pure returns (uint256);
}

library RewardMath {
    function accrue(uint256 eligibleDepth, uint256 rate, uint256 dt) internal pure returns (uint256 reward); // mulDiv, RATE_SCALE
    function eligible(uint256 sampleStart, uint256 sampleNow, uint256 commitment) internal pure returns (uint256);
}
```

---

## 8. Access-control matrix

| Function group | Anyone | Curator | Sponsor | Share holder | PoolManager |
|---|---|---|---|---|---|
| `createVault`, `seed`, `deposit` | ✔ | ✔ | ✔ | ✔ | |
| `rerange`, `deployIdle`, `setCommitment`, `claimCuratorFees` | | ✔ (own vault) | | | |
| `fundStandby`, `setStandbyRate` | | | ✔ | | |
| `requestRedeem`, `cancelRedeem`, `claimRedeem` | | | | ✔ (own tickets) | |
| `checkpoint`, `flagBreach`, `pokeStress` | ✔ | ✔ | ✔ | ✔ | |
| `unlockCallback` and hook callbacks | | | | | ✔ |

## 9. Storage layout plan

Document the final layout in `ARCHITECTURE.md` §7. Rules: pack `Vault` into at most four slots; keep hot per-swap state (`lastObservationTs`, `lastTick`, `stressState`, `stressStartedAt`, `belowExitSince`, `rearmBlocked`) in one slot; immutables for all `Config` fields; no dynamic arrays except observations, vault ranges (bounded) and tickets (append-only mapping keyed by id).

## 10. Gas notes

Per-swap cost is the cost every trader pays; keep `beforeSwap` minimal (see TESTING §7 for budgets). Move anything view-heavy into the lens. Avoid reading more than one position per vault in swap paths; swap paths never read vault positions.
