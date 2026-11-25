# CLAUDE.md — Ballast

> **Ballast: depth that can't leave when the liquidation arrives.**
> A Uniswap v4 hook that lets curators commit liquidity to the price band where liquidations will sell, locks that liquidity against withdrawal while the market is under stress, and publishes the committed depth on-chain so lending risk models can size collateral caps from depth that is actually guaranteed.

This file is the entry point for Claude Code. Read it fully before touching any code. It tells you what we are building, why, the design decisions already made, the engineering bar, and how to work in this repository.

---

## 0. How to use this file

### 0.1 Order of authority
1. Instructions from the human maintainer in the current session.
2. This file (`CLAUDE.md`) on scope and process.
3. `docs/SPEC.md` and `docs/CONTRACTS.md` on behavioural detail (they win over §6 of this file, per §18), then `docs/MATH.md`, `docs/THREAT_MODEL.md`.
4. `docs/DECISIONS.md` (architecture decision records you write as you go).
5. Code comments and NatSpec.

If two sources conflict, **stop and ask**. Do not silently pick one.

### 0.2 Markers used in this file
| Marker | Meaning | What you do |
|---|---|---|
| **DECISION D-n** | Settled design choice | Implement it. Changing it needs an ADR in `docs/DECISIONS.md` and human approval. |
| **VERIFY** | An API/flag/address/version fact that I (the author) am not certain of | Confirm against the pinned dependency source under `lib/` or the official Uniswap docs before relying on it. Never trust memory for signatures, flag bits, chain IDs or addresses. |
| **OPEN Q-n** | Unresolved question | Ask the human at the start of the session. Do not guess. |
| **INV-n** | A system invariant | Must be encoded as an invariant/fuzz test. |
| **G-n** | A product guarantee | Must be demonstrable by a named test and in the demo. |

### 0.3 Non-negotiables
- **This hook custodies depositors' funds.** Every change is security-critical. Prefer boring, explicit, well-tested code over clever code.
- **Never invent** contract addresses, ABIs, function signatures, library paths or flag values. Read them from `lib/`, official docs, or ask.
- **Never weaken a test to make it pass.** If a test fails, the code or the spec is wrong. Fix the root cause or raise it.
- **Do not write the pitch.** The hackathon rubric marks down AI-produced presentations. You may write technical docs, READMEs and code. You must not write presentation scripts, speaker notes, or narration for the human's demo. If asked for one, remind the human of this and offer an outline of technical facts instead.
- Keep secrets out of git (`.env`, keys). Use `cast wallet` keystores. Provide `.env.example` only.

---

## 1. What we are building

### 1.1 One paragraph
Ballast is a Uniswap v4 hook plus a small periphery. Every pool using it has **hook-owned liquidity only**: no one can add or remove liquidity except through the hook. **Curators** run vaults inside the pool, choosing ranges and a **committed depth** target. **Depositors** hold ERC-6909 shares of a vault. A **sponsor** (for example a collateral issuer or a lending protocol's risk DAO) streams a **standby fee** to vaults in proportion to verified committed depth. In exchange, the hook enforces commitments: withdrawals go through an exit-notice queue, and when the pool's price falls sharply versus its own TWAP (**stress**), the queue freezes until the market calms or a hard maximum lock elapses. A read-only **lens** exposes committed and live depth so lending protocols and risk managers can size supply caps from depth that cannot walk away.

### 1.2 The problem (why this is worth building)
Lending risk managers set collateral supply caps from DEX depth. Chaos Labs' stated methodology on Aave governance sets the supply cap at roughly **twice the liquidity available at the liquidation-penalty price impact**. But that DEX liquidity is uncommitted: LPs can withdraw at any time, and the same governance threads warn that liquidity may fall once incentives end. Governance threads for LsETH, weETH (Plasma) and rsETH document thin depth (single-digit millions of dollars at 5.5–7.5% price impact). When liquidations hit, thin depth means high slippage, unprofitable liquidations and bad debt. Issuers already pay to bootstrap liquidity (for example the Mantle deployment thread), but they pay for TVL that can leave.

Ballast turns "depth that exists right now" into "depth that is committed, enforced by the pool, and measurable on-chain".

Primary sources (paraphrase; do not quote at length in docs):
- https://governance.aave.com/t/arfc-onboard-usde-to-aave-v3-on-ethereum/17690 (supply-cap methodology; risk that liquidity falls when incentives end)
- https://governance.aave.com/t/arfc-onboard-lseth-to-aave-v3-core-instance/22957/3 (LsETH depth / price impact)
- https://governance.aave.com/t/direct-to-aip-weeth-e-mode-risk-parameter-adjustment-on-aave-v3-plasma-instance/23381 (weETH depth)
- https://governance.aave.com/t/arfc-prime-instance-wsteth-borrow-rate-rseth-supply-cap-update/20644 (rsETH depth)
- https://governance.aave.com/t/arfc-deploy-aave-v3-on-mantle/20542/14 (issuers bootstrapping liquidity)

### 1.3 Track and rubric context
Hackathon: Uniswap v4 hooks, track **Active Management & Curated Liquidity**. Judging categories, each 0–5: Original Idea, Unique Execution (v4 primitives, `BaseHook`/`getHookPermissions`, sound engineering, solid tests), Impact, Functionality (working deployment, ideally Unichain Sepolia, passing tests, end-to-end demo), Presentation. See §14 for the mapping from rubric to repository evidence.

### 1.4 Name
"Ballast" is a working name. Its availability on GitHub/X/the hackathon page is unchecked (**OPEN Q-1**).

---

## 2. Actors

| Actor | Who | Powers | Trust assumption |
|---|---|---|---|
| **Sponsor** | Issuer, lending DAO, risk team | Funds the standby pool, sets the standby rate within immutable bounds | Cannot move, freeze or redirect depositor funds |
| **Curator** | Professional liquidity manager | Creates a vault, sets ranges and commitment, re-ranges, earns a capped performance cut | Cannot withdraw depositor funds; bounded by coverage and lock rules |
| **Depositor** | Passive LP following a curator | Deposits/redeems proportional shares | Accepts exit notice and stress lock |
| **Risk consumer** | Lending protocol, risk manager, dashboard | Reads depth views | Trusts only on-chain state |
| **Anyone** | Permissionless pokers | Can call `poke`, `checkpoint`, `flagBreach`, settle stress state | None |
| **Trader / liquidator** | Swaps against the pool | Normal swaps | None |

There is **no owner, no admin, no pause, no upgrade path** (D-1).

---

## 3. Product guarantees and non-goals

### 3.1 Guarantees (each needs a named test and appears in the demo)
- **G-1 Hook-only liquidity.** No liquidity can be added to or removed from the pool except by the hook itself. Therefore the pool's whole depth is committed depth.
- **G-2 Oracle-free proportional shares.** Deposits and redemptions are proportional, in kind, and denominated in liquidity. There is no NAV, no price oracle and no spot-price valuation in share accounting.
- **G-3 Stress lock.** While the pool is in stress, no vault liquidity can leave the pool, bounded by `maxStressLock` so depositors are never trapped indefinitely.
- **G-4 Exit notice.** Exits mature after `exitNotice`. Depth reported to risk consumers is net of exits maturing inside the consumer's horizon.
- **G-5 Pay only for verified depth.** Standby fees accrue only on conservatively sampled, coverage-compliant depth, and stop when coverage breaks.
- **G-6 No privileged custody.** No function, role or parameter lets any address move or freeze depositor funds outside the rules above.

### 3.2 Non-goals for v1 (do not build; do not drift toward them)
- Native ETH pools (reject native currency).
- Fee-on-transfer, rebasing or blocklist tokens (document as unsupported).
- Upgradeable proxies, owners, pausers, governance tokens.
- Multi-pool vaults, cross-chain, auctions for the standby rate, IL protection, price-loss insurance.
- A real lending-protocol integration (we ship a reference advisor view only).
- `BeforeSwapDelta`/return-delta hooks. Ballast does not need them. Do not add them to chase the rubric.
- Sponsor withdrawal of standby funds (ADR-021): funds are not withdrawable in v1; the sponsor stops spending by setting the rate to zero.
- Any claim that depositors are protected from price losses. The lock **traps risk on purpose**; it does not remove it. Docs must say this plainly.

---

## 4. Architecture

### 4.1 Contracts

| Contract / library | Kind | Responsibility |
|---|---|---|
| `BallastHook` | Hook (`BaseHook`, shares ledger, unlock callback) | Hook callbacks, vault lifecycle, stress machine, standby accrual, custody via PoolManager |
| `BallastLens` | Read-only periphery | Depth views for risk consumers (`IBallastDepthOracle`). Keeps the hook under the 24,576-byte size limit |
| `SupplyCapAdvisor` | Read-only reference | Converts depth into a suggested supply cap (multiplier × guaranteed depth) |
| `Observations` | Internal library | Ring-buffer tick-cumulative oracle (v3-style semantics, own implementation) |
| `BandMath` | Internal library | bps ↔ ticks, band edges in the liquidation direction |
| `DepthMath` | Internal library | Absorbable-collateral math over position/band overlap |
| `StressMachine` | Internal library | Pure state transition function for CALM / STRESS / RECOVERING |
| `VaultMath` | Internal library | Proportional deposit/redeem maths with explicit rounding |
| `RewardMath` | Internal library | Standby accrual maths |
| `interfaces/*` | Interfaces | `IBallastHook`, `IBallastLens`, `IBallastDepthOracle`, events and errors |

**DECISION D-2:** one hook instance serves exactly one pool (bound at `beforeInitialize`), with immutable configuration. A second `initialize` for another pool reverts.

**DECISION D-3:** logic lives in small internal libraries with pure/`view` functions that are unit- and fuzz-testable in isolation. The hook contract orchestrates. If bytecode approaches the size limit, move read-only code to `BallastLens`; do not use external library linking (it complicates address mining).

**DECISION D-4 (ADR-030):** use OpenZeppelin `uniswap-hooks` v1.2.1 for `BaseHook` (the rubric names `BaseHook` and `getHookPermissions`) and `CurrencySettler` (claims-based settlement via its `burn`/`claims` flags). `v4-periphery` is a test-only dependency (PositionManager, Permit2): it no longer ships `BaseHook` or `HookMiner`. We write our own minimal `HookMiner` in `script/`. Pins are in the "Pinned dependencies" table of `docs/DECISIONS.md`; the API is recorded in `docs/VERIFICATION.md` F-1.

### 4.2 Repository layout

```
ballast/
├── CLAUDE.md                      # this file
├── README.md                      # public-facing overview, quickstart, results, links
├── SECURITY.md                    # trust model, known limitations, disclosure
├── CHANGELOG.md
├── LICENSE                        # MIT unless the human says otherwise (OPEN Q-2)
├── foundry.toml
├── remappings.txt
├── .env.example
├── .github/workflows/ci.yml       # fmt, build, test, coverage, slither
├── docs/
│   ├── SPEC.md                    # normative behaviour (state machines, formulas, edge cases)
│   ├── CONTRACTS.md               # contract/interface reference: signatures, access, events, errors
│   ├── ARCHITECTURE.md            # diagrams, call flows, storage layout
│   ├── MATH.md                    # depth, band, TWAP, rounding proofs/sketches
│   ├── THREAT_MODEL.md            # attackers, assets, mitigations, residual risk
│   ├── ECONOMICS.md               # standby pricing, curator incentives, put-writing framing
│   ├── TESTING.md                 # test taxonomy, invariants, how to run
│   ├── DEPLOYMENT.md              # networks, mining, verification, manifest
│   ├── SIMULATION.md              # crash simulation protocol and results
│   ├── RUBRIC_MAP.md              # rubric → evidence in repo
│   ├── DECISIONS.md               # ADRs (append-only)
│   └── VERIFICATION.md            # evidence for every VERIFY item
├── src/
│   ├── BallastHook.sol
│   ├── periphery/
│   │   ├── BallastLens.sol
│   │   └── SupplyCapAdvisor.sol
│   ├── interfaces/
│   │   ├── IBallastHook.sol
│   │   ├── IBallastLens.sol
│   │   ├── IBallastDepthOracle.sol
│   │   └── IBallastEvents.sol / IBallastErrors.sol
│   ├── libraries/
│   │   ├── Observations.sol
│   │   ├── BandMath.sol
│   │   ├── DepthMath.sol
│   │   ├── StressMachine.sol
│   │   ├── VaultMath.sol
│   │   └── RewardMath.sol
│   └── types/Types.sol            # structs, enums, user-defined value types
├── test/
│   ├── unit/                      # per-library and per-function tests
│   ├── fuzz/                      # property tests on libraries and vault maths
│   ├── invariant/                 # handler-based invariant suite
│   ├── fork/                      # tests against deployed PoolManager (Unichain Sepolia)
│   ├── scenario/                  # multi-actor narratives (crash, breach, drought)
│   └── utils/                     # fixtures, handlers, mock tokens, actors, routers
├── script/
│   ├── DeployBallast.s.sol        # own HookMiner (script/utils) + CREATE2 deployment + pool init
│   ├── CreatePool.s.sol
│   ├── SeedVaults.s.sol
│   ├── FundStandby.s.sol
│   ├── RunCrash.s.sol             # scripted crash against Ballast pool and control pool
│   └── Verify.s.sol / verify.sh
├── analysis/                      # simulation output tooling and results (see §13)
├── config/addresses.json          # official addresses per chain, with source links
└── deployments/<chainId>.json     # our deployed addresses (written by scripts)
```

Bootstrap from the official v4 template if convenient (**VERIFY** the template repository and its fixtures such as `Deployers`/`EasyPosm`) and then reshape to this layout.

### 4.3 High-level data flow

```
 Sponsor ──fundStandby──▶ ┌──────────────────────────── BallastHook ────────────────────────────┐
                          │  vaults[1..N]  positions[]  shares (ERC-6909)  stress machine       │
 Curator ─create/rerange─▶│  observation ring buffer (tick cumulative)   standby accounting     │
 Depositor ─deposit──────▶│  idle balances (PoolManager claims)          curator records        │
 Depositor ─request/claim▶└───────────┬─────────────────────────────────────────▲───────────────┘
                                      │ unlock / modifyLiquidity / settle / take │ beforeSwap, beforeAdd/Remove
                                      ▼                                          │
                               ┌──────────────┐        swaps ◀──── Trader / liquidator
                               │ PoolManager  │
                               └──────────────┘
 Risk consumer ──▶ BallastLens (committedDepth, liveDepth, lockState, records) ──▶ SupplyCapAdvisor
```

---

## 5. Domain model

Sketches only. Finalize packing and widths during implementation, record the storage layout in `docs/ARCHITECTURE.md`, and add `@custom:` NatSpec for units.

```solidity
/// Immutable configuration, validated in the constructor.
struct Config {
    Currency collateral;         // the asset being liquidated (sold into the pool)
    Currency quote;              // the asset liquidators receive
    address  sponsor;
    address  initializer;        // only address allowed to initialize the pool (ADR-014)
    uint24   fee;                // static LP fee the pool must use
    int24    tickSpacing;        // tick spacing the pool must use
    uint16   bandBps;            // X: depth band, price impact below the anchor
    uint16   stressEnterBps;     // θ: short TWAP deviation that enters stress
    uint16   stressExitBps;      // < θ (hysteresis), e.g. θ/2
    uint32   anchorWindow;       // seconds, TWAP window for the anchor price
    uint32   shortWindow;        // seconds, TWAP window for the stress test
    uint32   calmDuration;       // seconds below exit threshold before CALM
    uint32   maxStressLock;      // hard cap on how long a stress episode can lock exits
    uint32   exitNotice;         // seconds between requestRedeem and claim
    uint32   rerangeGrace;       // seconds to restore coverage after anchor drift
    uint32   maxAccrualInterval; // cap on a single accrual interval
    uint16   maxCuratorFeeBps;
    uint32   observationInterval;
    uint16   observationCardinality;
    uint128  maxStandbyRate;     // upper bound for the sponsor-set rate
}

struct Position { int24 tickLower; int24 tickUpper; uint128 liquidity; }

struct Vault {
    address curator;
    uint16  curatorFeeBps;
    uint8   positionCount;       // <= MAX_POSITIONS
    uint128 commitment;          // D_v: collateral amount the vault promises to absorb inside the band
    uint128 pendingCommitment;   // reduction takes effect after exitNotice
    uint40  pendingCommitmentAt;
    uint128 idle0; uint128 idle1;            // undeployed balances, shared pro rata by shares
    uint128 curatorOwed0; uint128 curatorOwed1;
    uint40  lastCheckpoint;
    uint128 lastDepthSample;     // conservative depth at lastCheckpoint
    uint40  breachSince;         // 0 if covered
}

struct RedeemTicket { uint256 vaultId; address owner; uint128 shares; uint40 maturity; }   // receiver is chosen at claim time (ADR-016)

struct CuratorRecord {           // exact on-chain counters, no off-chain inputs
    uint64  coveredSeconds;      // seconds with coverage >= commitment while tracked
    uint64  trackedSeconds;
    uint32  rerangeCount;
    uint32  breachCount;
    uint32  stressEpisodesHeld;  // stress episodes during which commitment stayed in place
    uint256 depthSeconds;        // sum of eligible depth x seconds
}

enum LockState { CALM, STRESS, RECOVERING }
```

Constants: `MAX_VAULTS = 16`, `MAX_POSITIONS = 8`, `MINIMUM_SHARES = 1e3`. All loops must be bounded by these.

---

## 6. Mechanism specification

### 6.1 Pool binding (`beforeInitialize`)
- `sender == config.initializer`, otherwise revert `PoolInitializerOnly(sender)` (ADR-014). The deploy script deploys the hook and initializes the pool in one broadcast.
- `key.hooks == address(this)`; pool not already bound (D-2).
- Fee must be static: reject `LPFeeLibrary.DYNAMIC_FEE_FLAG`; `key.fee == config.fee` and `key.tickSpacing == config.tickSpacing`, otherwise `InvalidPoolKey`.
- Neither currency may be native (zero address).
- One currency equals `config.collateral`, the other `config.quote`. Store `collateralIsCurrency0`.
- Tick spacing is fixed by `config.tickSpacing`. All range ticks must be multiples of it.
- Store `poolId`. `afterInitialize` seeds observation 0 with the initial tick and timestamp.

### 6.2 Hook permissions (`getHookPermissions`)
Enable only what is needed (**DECISION D-5**):

| Flag | Value | Why |
|---|---|---|
| `beforeInitialize` | true | Bind pool, validate key |
| `afterInitialize` | true | Seed oracle |
| `beforeAddLiquidity` | true | Revert for external callers (G-1) |
| `beforeRemoveLiquidity` | true | Revert for external callers (G-1) |
| `beforeSwap` | true | Oracle write and stress evaluation |
| everything else | false | Minimal permission surface; includes all return-delta flags |

**VERIFY** in the pinned `lib/v4-core/src/libraries/Hooks.sol`: (a) flag constants (use `Hooks.*_FLAG` names, never hard-code bits); (b) that the PoolManager does not invoke a hook's callbacks when the hook itself is the caller of `modifyLiquidity` (the "no self call" behaviour). Ballast relies on (b): the hook's own liquidity operations bypass its callbacks, so `beforeAddLiquidity`/`beforeRemoveLiquidity` can **revert unconditionally** for everyone else. Add a test proving PositionManager and a plain router both fail to add/remove liquidity (G-1).

**VERIFIED (docs/VERIFICATION.md F-3):** the Unichain Sepolia PoolManager's runtime code equals Ethereum mainnet's apart from its embedded self-address, and `test/fork/HooksOnChain.t.sol` exercises all five of Ballast's flags against it on a fork. Keep that test and the deploy script's address-flag assertion; re-run the fork test before mining an address on any other chain. A funded testnet deployment is due in M2 and M9.

### 6.3 Oracle (`Observations`)
- Ring buffer of `{ uint32 timestamp, int56 tickCumulative }`. Own implementation; v3's `Oracle.sol` is GPL, so do not copy it. Match its semantics.
- **Running accumulator (ADR-013).** State `(lastSwapTs, lastTick, cumulative)`. At the start of every `beforeSwap` whose timestamp differs from `lastSwapTs`, using the **pre-swap tick** (`slot0.tick`): `cumulative += tick_preSwap × (now − lastSwapTs)`. Because price only changes at swaps, the accumulator is exact. Never accumulate twice in the same timestamp (this is what makes in-block manipulation worthless).
- Only the ring-buffer **snapshots** are rate-limited by `observationInterval`. Snapshot values are exact. The current cumulative is exact (`cumulative + currentTick × (now − lastSwapTs)`).
- `cumulativeAt(secondsAgo)` interpolates between neighbouring snapshots (binary search); exact only if no swap occurred between them. Error bound in `docs/MATH.md` §4: TWAP error ≤ `observationInterval × max tick swing / window`. `twapTick(window)` = Δcumulative / window. Rounding: toward negative infinity, like v3.
- Cardinality is fixed at construction; hard minimum `ceil(anchorWindow / observationInterval) + 1`, recommended default 1.1× that. **Warm** means the anchor window is fully covered by retained snapshots (this implies the short window is covered). If not warm, use the oldest snapshot and flag `oracleWarm = false`; the stress machine stays CALM and fee accrual continues while warming.
- Anchor `A = twapTick(anchorWindow)`. Short price `S = twapTick(shortWindow)`.

### 6.4 Stress machine (`StressMachine`)
Direction matters. Liquidations sell collateral into the pool, so price moves in the **liquidation direction**: ticks decrease if collateral is currency0, increase if collateral is currency1. Define `dev = sign × (A − S)` (positive means the short TWAP is below/above the anchor in the liquidation direction).

```
        dev ≥ θ_enter                       dev < θ_exit for calmDuration
CALM ───────────────────▶ STRESS ───▶ RECOVERING ───────────────────────▶ CALM
                            ▲   dev < θ_exit │
                            └───────────────┘ (dev ≥ θ_enter again)
```
- **Lock window.** On entering STRESS from CALM, set `stressStartedAt`. It is set on that transition only: RECOVERING → STRESS does not reset it (ADR-019). The lock is active while state ≠ CALM **and** `now < stressStartedAt + maxStressLock`.
- **No re-arming (D-6).** After the lock expires, it cannot re-arm until the state has returned to CALM at least once. This bounds how long anyone can be trapped.
- Evaluation is lazy: run at most once per `observationInterval` inside `beforeSwap`, at the start of every state-changing function (including `claimRedeem`, so no poke is needed to release a lock), and via public `pokeStress()`. Views use a pure preview of the transition. Accepted approximation: continuity of the calm period is checked at evaluation points only. A pure `StressMachine.next(state, dev, now, ctx)` function holds all logic and is fuzzed independently.
- Manipulation resistance: transitions use TWAPs, not spot, and the short window must exceed a few observation intervals. Document the attacker cost model in `THREAT_MODEL.md`.

### 6.5 Band and depth maths (`BandMath`, `DepthMath`)
Definitions:
- **Band** = the price interval from the anchor price `P_A` to `P_A × (1 − X)` in the liquidation direction, with `X = bandBps / 10_000`.
- **Absorbable collateral** of liquidity `L` over a price interval `[Pa, Pb]` = the amount of collateral that must be sold into the pool to move the price across that interval. If collateral is currency0: `SqrtPriceMath.getAmount0Delta(sqrtPa, sqrtPb, L)`. If collateral is currency1: `getAmount1Delta`. Round **down** (conservative).
- **committedDepth_v** = sum over the vault's positions of absorbable collateral over `position range ∩ band`. It is static in spot price (it depends on ranges and the anchor only). Used for coverage and rewards.
- **liveDepth(impactBps)** = absorbable collateral from the **current spot** price down to `spot × (1 − impactBps)`, over all pool liquidity (valid because all liquidity is hook-owned), net of redeem tickets maturing within the consumer's horizon (§6.9). Used by risk consumers.

Implementation notes: convert bps to ticks conservatively; clamp to `MIN_TICK/MAX_TICK`; use `FullMath.mulDiv`; document every rounding direction in `docs/MATH.md` and prove with fuzz tests that `DepthMath` never overstates depth versus a brute-force swap simulation on a fork of the pool (INV-9).

### 6.6 Vault lifecycle

**Create.** `createVault(Range[] ranges, uint128 commitment, uint16 curatorFeeBps)`. Permissionless; `msg.sender` is the curator; at most `MAX_VAULTS`. Ranges aligned to tick spacing; at most `MAX_POSITIONS`; no duplicates.

**Deposit (proportional, in kind; D-7).** `deposit(vaultId, shares, amount0Max, amount1Max, receiver)`:
1. Run `_checkpoint(vault)` (accrue standby, crystallize fees; see §6.7). Revert if STRESS/RECOVERING (deposits are blocked under stress) or if the transaction has already swapped the pool (transient flag; the hook sets it in `beforeSwap`).
2. For each position, `ΔL_i = ceilDiv(L_i × shares, totalShares)`; add that liquidity via `modifyLiquidity` from inside the unlock.
3. Also require `idle0/idle1` proportional slices, rounded up.
4. Depositor pays exactly the PoolManager deltas plus idle slices; revert if above `amount*Max`.
5. Mint shares. The **first** deposit into a vault uses the dedicated, **curator-only** `seed(vaultId, liquidities, amount0Max, amount1Max, receiver)` entrypoint (see `docs/CONTRACTS.md`; the receiver may be anyone): it mints `INITIAL_SHARES` (1e18) and permanently burns `MINIMUM_SHARES` to `address(0)`. `deposit` reverts on an unseeded vault.
Rules: never poke or modify a position whose recorded liquidity is zero (v4 is believed to revert; **VERIFY**). Never read `balanceOf` for accounting (donations must not move share maths); all balances are internal ledgers and PoolManager deltas; treat PoolManager-reported deltas as ground truth, never recompute amounts.

**Redeem.** Two steps:
1. `requestRedeem(vaultId, shares)` moves shares into hook escrow and creates a ticket with `maturity = now + exitNotice`. Escrowed shares still earn and still bear risk.
2. `claimRedeem(ticketId, receiver)` is callable by the ticket owner or an approved operator and chooses the receiver at claim time. It evaluates stress first and requires `now ≥ maturity` and the lock inactive. It runs `_checkpoint`, then removes `ceil/floor`-correct proportional liquidity from every position (rounded in the vault's favour), adds the proportional idle slice, burns the shares and `take`s tokens to the receiver. `cancelRedeem` returns shares.

**Re-range (the active management).** `rerange(vaultId, Range[] newRanges)`, curator only, `nonReentrant`:
- **CALM:** remove all liquidity, re-add into `newRanges` using recovered tokens plus idle, in one `unlock` (flash accounting nets deltas; only the net is settled). After the operation, `committedDepth_v ≥ commitment` must hold or the call reverts. Accrual uses `min(depthBefore, depthAfter)` for the interval so a re-range cannot be gamed.
- **STRESS/RECOVERING:** `rerange` reverts (it is CALM-only). Additions during stress go through the separate `deployIdle(vaultId, range, liquidity)`, which uses idle balances only and never reduces liquidity (ADR-017).
- Tokens that cannot be placed stay in `idle` and are shared pro rata.

**Commitment changes.** Increases apply immediately. Decreases apply after `exitNotice` (`pendingCommitment`).

**Coverage and breach.** In CALM, anchor drift can push `committedDepth_v` below `commitment`. The curator has `rerangeGrace` to fix it. After that, anyone may call `flagBreach(vaultId)`; the vault stops accruing standby fees until coverage is restored and its record logs the breach. In STRESS coverage is **not** enforced, because liquidity being consumed by the falling market is the product working as intended.

### 6.7 Standby fund and accrual (`RewardMath`)
- **DECISION D-8:** the standby fee is paid in the pool's **quote** currency, so rewards land directly in the vault's `idle` balance and are shared by shares pro rata, in kind. This removes per-user reward debt and any need to hook ERC-6909 transfers.
- `fundStandby(amount)`: sponsor deposits quote currency (held as PoolManager claims). `setStandbyRate(rate)`: sponsor only, `rate ≤ maxStandbyRate`. Rate unit: quote-currency wei per collateral wei of eligible depth per second (fixed-point, documented).
- **Checkpoint.** `_checkpoint(vault)` computes `eligibleDepth = min(d_start, d_now, commitment)` where each depth sample is `d = min(anchor-based D_v, that vault's live depth measured from spot)` in every state including STRESS (ADR-025; conservative across the interval), limits the interval to `maxAccrualInterval`, computes `reward = eligibleDepth × rate × Δt`, caps it by the fund balance, credits `(1 − curatorFeeBps)` to `idle` and the curator cut to `curatorOwed`, and updates the curator record. Zero reward if in breach.
- Every share-changing action checkpoints **before** it changes shares. This is what prevents reward sniping: a new depositor pays proportionally for idle that already includes credited rewards.
- Sponsor funds are not withdrawable in v1 (ADR-021). The sponsor stops spending by setting the rate to zero and should fund in tranches.
- If the fund runs dry, accrual stops and `StandbyDepleted` is emitted. The stress lock still holds for an active episode. The depth views simply decay as exits mature. This is intentional and must be documented: the guarantee is "depth plus notice", not forever.
- **Trading fees** are crystallized the same way: poke each position (`liquidityDelta = 0`), take `feesAccrued`, split the curator cut, add the rest to `idle`. **Lesson from the OpenZeppelin `LiquidityPenaltyHook` audit:** in v4, any liquidity increase auto-collects accrued fees. Never gate behaviour on uncollected fees at removal time.

### 6.8 Curator record
Exact on-chain counters (see `CuratorRecord`). Updated at checkpoints. No off-chain inputs, no historical performance claims. The record is the reputation primitive we ship; weighting AUM by it is future work and must not be implied in code or docs.

### 6.9 Views for risk consumers (`IBallastDepthOracle`)
```solidity
interface IBallastDepthOracle {
    function committedDepth() external view returns (uint256 collateralAmount);            // anchor band, compliant vaults only
    function liveDepth(uint16 impactBps, uint32 horizon) external view returns (uint256);  // from spot, net of exits maturing within `horizon`
    function lockState() external view returns (LockState state, uint40 lockedUntil);
    function vaultRecord(uint256 vaultId) external view returns (CuratorRecord memory);
    function vaultStatus(uint256 vaultId) external view returns (uint128 depth, uint128 commitment, bool inBreach);
}
```
**Consumer guidance:** `liveDepth` is the number lenders should use to size caps; `committedDepth` is for coverage and rewards. `liveDepth` and the pool-wide views iterate vault positions (the whole pool, by G-1); they never scan ticks (ADR-023).

`liveDepth` subtracts, for each vault, the depth fraction represented by tickets maturing within `horizon`. Loops are bounded by `MAX_VAULTS × MAX_POSITIONS`. `SupplyCapAdvisor.suggestedCap(multiplierWad, impactBps, horizon)` returns `multiplier × liveDepth(...)` as a reference only (the Chaos Labs methodology uses a 2× multiplier; make it a parameter).

### 6.10 Default parameters (testnet/demo; production is a sponsor choice)

| Parameter | Default | Bounds (constructor-validated) |
|---|---|---|
| `bandBps` (X) | 750 | 100 – 2,500 |
| `stressEnterBps` (θ) | 300 | 50 – `bandBps` |
| `stressExitBps` | θ / 2 | < θ |
| `anchorWindow` | 24 h | ≥ 1 h |
| `shortWindow` | 15 min | ≥ 5 min and < `anchorWindow` |
| `calmDuration` | 1 h | ≥ `shortWindow` |
| `maxStressLock` | 24 h | ≤ 7 d |
| `exitNotice` | 6 h | ≤ 3 d (0 allowed in tests) |
| `rerangeGrace` | 1 h | ≥ `observationInterval` |
| `maxAccrualInterval` | 1 h | ≥ `observationInterval` |
| `maxCuratorFeeBps` | 2,000 | ≤ 5,000 |
| `observationInterval` | 60 s | ≥ 1 s |
| `observationCardinality` | recommended `ceil(anchorWindow / observationInterval) × 1.1`; hard minimum `ceil(anchorWindow / observationInterval) + 1` | ≤ 65,535 |

---

## 7. Uniswap v4 integration notes (read before writing hook code)

Everything here marked **VERIFY** must be checked against the pinned sources in `lib/`.

1. **Unlock pattern.** Every operation that touches pool liquidity or balances is a public entrypoint that encodes an action struct and calls `poolManager.unlock(data)`. `unlockCallback` (restricted to the PoolManager) decodes and executes. When the callback returns, every currency delta must be zero or the PoolManager reverts. Flash accounting is why `rerange` can remove and re-add liquidity and settle only the net.
2. **Delta signs and settlement.** A positive delta means the hook is owed tokens (`take` them or `mint` PoolManager claims). A negative delta means the hook owes tokens (`sync(currency)`, transfer, `settle()`, or `burn` claims). **Do not hand-roll this.** Use a vetted settlement helper (OpenZeppelin `uniswap-hooks` or the v4-core test util pattern) and review it. For depositor funds, move tokens straight from the depositor to the PoolManager between `sync` and `settle`.
3. **`modifyLiquidity` return values.** It returns `(callerDelta, feesAccrued)`. `callerDelta` **includes** accrued fees. Separate them (`principal = callerDelta − feesAccrued`) or the depositor will be charged/credited for other people's fees. Crystallize fees (zero-liquidity poke) before changing shares (§6.7).
4. **Position identity.** Owner = the hook, `salt = bytes32(vaultId << 8 | slot)`. Use v4's position-key helper. Read liquidity with the `StateLibrary` helpers (`getSlot0`, `getPositionInfo`/`getPositionLiquidity`, tick info). We also keep our own `Position[]` per vault; add an invariant that the two always agree.
5. **Rounding.** The PoolManager rounds amounts in the pool's favour: adds round up what the caller pays, removals round down what the caller receives. Our share maths must round in the vault's favour on top of that. Never recompute amounts the PoolManager has already reported.
6. **Self-calls skip callbacks.** The hook's own `modifyLiquidity` does not trigger its own `before/afterAddLiquidity` (**VERIFY**, §6.2). This is the basis of G-1.
7. **Hook address.** Hook permissions are encoded in the low bits of the hook's address. Deploy through CREATE2 with our own `HookMiner` in `script/utils` (v4-periphery no longer ships one; ADR-030). In Foundry scripts use the standard CREATE2 deployer constant (`CREATE2_FACTORY` in `forge-std`, code present on chain 1301). The deployment script must assert `address(hook)` flags equal `getHookPermissions()`.
8. **Transient storage.** Build for `evm_version = "cancun"`. Use transient storage for (a) the reentrancy guard and (b) the per-transaction flags `SWAPPED` and `VAULT_OP`. **DECISION D-9:** vault operations and swaps may not share a transaction in either order (`beforeSwap` reverts if `VAULT_OP` is set; `seed`, `deposit`, `claimRedeem`, `rerange` and `deployIdle` set `VAULT_OP` and revert if `SWAPPED` is set). This is defence in depth, not a core dependency, and it can break zap-style integrations, so record it in the ADR log and revisit if it hurts. **VERIFY** compiler and chain support for transient storage.
9. **Idle custody (D-10).** Idle balances and the standby fund are held as **PoolManager ERC-6909 claims** (`mint`/`burn`), not ERC-20 balances inside the hook. This keeps idle movements inside flash accounting. The vault **shares** token is the hook's own ERC-6909 (id = vaultId). Do not confuse the two ledgers; name them `shares` and `claims` in code. **VERIFY** whether to inherit v4-core's `ERC6909` or use another audited implementation. Fallback if this proves error-prone: hold idle as ERC-20 in the hook, with an ADR.
10. **Tokens.** ERC-20 only, no native currency. Fee-on-transfer, rebasing and blocklist tokens are unsupported; document it and add a test that documents the failure mode.
11. **Tick maths.** Use `TickMath` and `SqrtPriceMath`/`FullMath` from v4-core. Clamp to min/max ticks. Convert bps to ticks conservatively (round toward less depth).
12. **Network facts (VERIFY; never from memory).** Target chain: Unichain Sepolia (chain ID believed to be 1301). Take the PoolManager, PositionManager, Permit2 and router addresses from the official Uniswap deployments page and record them with source links in `config/addresses.json`. Reconfirm the chain ID and RPC from official Unichain docs.
13. **Toolchain.** Solidity 0.8.26 (**VERIFY** against v4-core/periphery pragmas), `evm_version = "cancun"`, `via_ir` if stack-too-deep requires it (record why). Dependencies: v4-core, OpenZeppelin `uniswap-hooks` (`BaseHook`, `CurrencySettler`; its nested `openzeppelin-contracts` v5.5.0 supplies `SafeERC20`), solady (`lnWad`, `ReentrancyGuardTransient`), forge-std, and v4-periphery for tests only. Exact commits are in the "Pinned dependencies" table of `docs/DECISIONS.md`.

---

## 8. Security model

### 8.1 Threats and required mitigations

| ID | Threat | Mitigation | Evidence |
|---|---|---|---|
| T1 | Anyone adds/removes liquidity outside the hook | Unconditional revert in `beforeAdd/RemoveLiquidity`; self-call skip | Test with PositionManager and plain router |
| T2 | Share inflation / donation | Internal ledgers only, `MINIMUM_SHARES`, requested-shares deposit model | Donation fuzz test |
| T3 | Push price to trigger stress and trap LPs | TWAP-based transitions, hysteresis, `maxStressLock`, no re-arming | Manipulation scenario test, cost model in THREAT_MODEL |
| T4 | Push price to suppress stress | Same TWAP guards; residual risk documented | Scenario test |
| T5 | Standby farming (thin edge liquidity, flash depth near checkpoints) | `min(start,end,commitment)` sampling, `maxAccrualInterval`, exit notice, re-range uses min(before, after) | Gaming scenario tests |
| T6 | Reward sniping by timing deposits | Checkpoint before every share change | Fuzz: no depositor gains from timing |
| T7 | Reentrancy (token callbacks, unlock re-entry) | Transient guard, checks-effects-interactions, ERC-20 only | Reentrancy attacker mock |
| T8 | Gas DoS via loops | `MAX_VAULTS`, `MAX_POSITIONS`, bounded views | Worst-case gas tests |
| T9 | Rounding drain | Explicit rounding helpers, vault-favouring | Token-conservation invariant |
| T10 | Oracle cold start / sparse swaps | `oracleWarm` flag, exact interpolation, cardinality sizing | Oracle tests |
| T11 | Sponsor stops funding | Documented; depth views decay honestly; no custody effect | Drought scenario |
| T12 | Curator mismanagement | Fee cap, visible record; **cannot be prevented**, only disclosed | Docs |
| T13 | Token transfer failure on payout | Revert whole tx so funds stay in the vault; receiver is chosen at claim time and can differ on retry | Failing-token mock |
| T14 | Sequencer timestamp skew | Coarse windows, no sub-minute logic | Parameter bounds |
| T15 | Wrong hook address bits; pool-initialization front-running | Deployment script assertion and test; `initializer`, fee and tickSpacing enforced in `beforeInitialize` | `DeployBallast` test; init-restriction tests |
| T16 | Swap/vault-operation sandwiching | Same-transaction guards (D-9); share maths independent of price | Guard tests |
| T17 | Misleading consumers of depth views | `liveDepth` nets exits within a horizon; guidance to use `liveDepth` | Docs, lens tests |
| T18 | Exit race at crash onset (matured tickets leave before the lock engages) | Accepted in v1; visible through `liveDepth` horizon netting; quantified | `ExitRace` scenario test |

Maintain `docs/THREAT_MODEL.md` with assets, trust boundaries, attacker capabilities, cost estimates for T3/T4 (price manipulation cost versus pool depth) and residual risks. State plainly that the stress lock traps depositors with price risk by design.

### 8.2 Invariants (each becomes an invariant or fuzz test)
- **INV-1** Every position in the pool has the hook as owner.
- **INV-2** For each vault, the sum of our recorded position liquidity equals the PoolManager's position liquidity.
- **INV-3** Claims solvency, per currency: PoolManager claims held by the hook ≥ Σ vault idle + Σ curatorOwed + standby fund (an inequality, since anyone can transfer claims to the hook). Principal conservation is checked through a ghost ledger of PoolManager-reported deltas, with dust always in the vault's favour.
- **INV-4** `totalSupply(vaultId)` equals the sum of balances plus escrowed shares plus burned minimum.
- **INV-5** Rounding never favours the actor: a deposit-then-immediate-redeem round trip never returns more than was paid.
- **INV-6** No liquidity leaves the pool while the lock is active, except after `maxStressLock` expiry.
- **INV-7** In CALM, after any curator operation, `committedDepth_v ≥ commitment` or the operation reverted.
- **INV-8** A vault accrues standby reward only if its depth sample is positive and it is not in breach. Total credited rewards never exceed total funded.
- **INV-9** `DepthMath` never overstates absorbable collateral relative to a brute-force swap simulation.
- **INV-10** `liveDepth(i, h₂) ≤ liveDepth(i, h₁)` for `h₂ ≥ h₁`, and `liveDepth ≤` total pool absorbable depth.
- **INV-11** Observation timestamps strictly increase and `tickCumulative` is consistent with recorded ticks.
- **INV-12** The stress machine only makes legal transitions; the lock cannot re-arm without an intervening CALM.
- **INV-13** No privileged address can change custody-relevant state. This is a static access-control test that enumerates all external selectors and their expected callers, plus an audit item; it is not a runtime invariant.
- **INV-14** `SWAPPED`/`VAULT_OP` guards: no transaction contains both a swap and a vault operation.
- **INV-15** Warm is monotonic: once the anchor window is covered by retained snapshots it never becomes uncovered (R-ORC-7).

---

## 9. Testing strategy

The test suite is a primary deliverable. A reader skimming `test/` should see a serious project.

### 9.1 Layers
1. **Unit** (`test/unit`): every library function and every external function, success and revert paths. Naming: `test_<Function>_<Behaviour>`, `test_RevertWhen_<Condition>`.
2. **Fuzz** (`test/fuzz`): `testFuzz_*` on `VaultMath`, `DepthMath`, `BandMath`, `RewardMath`, `StressMachine`, `Observations`. Bound inputs deliberately; do not use `vm.assume` to discard most runs.
3. **Differential** (`test/fuzz/Differential*.t.sol`): `DepthMath` vs brute-force swapping through a real PoolManager with the same liquidity; `Observations` vs a naive reference model; `StressMachine` vs a table-driven reference.
4. **Invariant** (`test/invariant`): handler-based, with ghost variables. Handler actions: create vault, deposit, request/claim/cancel redeem, re-range (calm and stress), swap in both directions and many sizes, warp time, poke, flag breach, fund standby, set rate. Actors: several curators, depositors, one sponsor, one trader. Implement INV-1…INV-14.
5. **Scenario** (`test/scenario`): readable narratives that double as demos:
   - `Crash.t.sol`: price falls through the band, lock engages, a liquidation-sized sell executes against committed depth, exits are blocked, the market recovers, exits clear.
   - `Breach.t.sol`: anchor drift breaks coverage, grace expires, flag, accrual pauses, curator restores.
   - `Drought.t.sol`: sponsor stops funding; accrual stops; depth views decay as exits mature.
   - `Manipulation.t.sol`: attacker pushes price to try T3/T4/T5/T6; assert the mitigation and record attacker cost.
   - `Control.t.sol`: same liquidity in a plain v4 pool (no hook) versus Ballast under the same shock (feeds §13).
   - `ExitRace.t.sol`: matured tickets exist at crash onset; quantifies how much matured-ticket liquidity can exit before the lock engages (T18).
6. **Fork** (`test/fork`): run key flows against the deployed PoolManager on the target chain. Skip cleanly when `RPC_URL` is missing. Pin the fork block.
7. **Gas** (`test/gas`): budget assertions and `.gas-snapshot`.

### 9.2 Bars
- Coverage: **≥ 95% lines and ≥ 90% branches** for `src/` (excluding mocks); CI fails below.
- Fuzz: default 1,000 runs locally, 10,000 in CI profile. Invariants: ≥ 256 runs × depth ≥ 128 locally; larger in CI.
- Static analysis: Slither clean or each finding explicitly justified in `docs/SLITHER_NOTES.md`. `forge fmt --check` in CI.
- No test may depend on wall-clock time, network (outside `fork/`) or ordering of other tests.

### 9.3 Gas budgets (targets; measure, record, and justify regressions > 5%)

| Path | Target |
|---|---|
| `beforeSwap`, no observation write, no stress evaluation | < 30k |
| `beforeSwap` with observation write and stress evaluation | < 80k |
| `deposit` (2 positions) | < 500k |
| `requestRedeem` | < 120k |
| `claimRedeem` (2 positions) | < 450k |
| `rerange` (2 → 2 positions) | < 700k |
| `committedDepth()` worst case (16 vaults × 8 positions), `view` | document |

### 9.4 Simulation pre-registration (integrity rule)
Before running the crash comparison, commit `analysis/PREREGISTRATION.md` stating: the scenario, price path, pool depth, liquidation size, metrics, and the **pass/fail bar** (for example, slippage on the liquidation sell versus the control pool, and zero lock violations). The human sets the bar (**OPEN Q-5**). Do not change the scenario or the bar after seeing results. Report failures honestly.

---

## 10. Engineering standards (the quality bar)

The goal is code that reads as a production protocol, not a hackathon script.

**Structure and clarity**
- Interface-first: define `IBallastHook`, `IBallastLens`, `IBallastDepthOracle`, events and errors before implementations. Every external function is declared in an interface.
- Contract layout follows the Solidity style guide: pragma, imports, errors, types, constants, immutables, storage, modifiers, constructor, external, public, internal, private. Use short section banners (`// ─── Vault lifecycle ───`).
- Small functions with one responsibility. Pure maths in libraries. The hook orchestrates and never contains formulas inline.
- No magic numbers. Every constant is named and documented with its unit.

**Documentation in code**
- NatSpec on every `external`/`public` function, event, error and struct: `@notice`, `@dev` (rounding direction, preconditions), `@param`, `@return`. Use `@custom:invariant INV-n` and `@custom:guarantee G-n` tags to tie code to the spec.
- Comment **why**, not what. Every non-obvious rounding choice states its direction and reason.
- Every `unchecked` block has a `// SAFETY:` comment with a short proof.
- Inline assembly only for transient-storage helpers or audited maths, each documented.

**Errors, events, state**
- Custom errors only (no revert strings), descriptive and parameterized, for example `StressLockActive(uint40 until)`, `CoverageBelowCommitment(uint128 depth, uint128 commitment)`.
- Emit an event for every state change: `VaultCreated`, `Deposited`, `RedeemRequested`, `RedeemCancelled`, `RedeemClaimed`, `Reranged`, `CommitmentChanged`, `StressEntered`, `StressExited`, `LockExpired`, `Checkpointed`, `BreachFlagged`, `BreachCleared`, `StandbyFunded`, `StandbyRateSet`, `StandbyDepleted`, `RewardCredited`, `CuratorFeeClaimed`. Index ids and addresses for indexers.
- Checks-effects-interactions everywhere. State-changing external functions that unlock are `nonReentrant` (transient guard).

**Forbidden**
- `tx.origin`, `selfdestruct`, `delegatecall`, upgradeable proxies, owner/pauser roles, unbounded loops, reliance on `balanceOf` for accounting, `block.number` for time, floating pragmas in `src/`, TODOs in merged code (use issues or `docs/`), commented-out code.

**Process**
- Conventional Commits (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`, `chore:`). Small commits; each one builds and passes tests.
- Every merged feature includes tests, NatSpec, and a docs update. Decisions that deviate from this file get an ADR.
- CI (`.github/workflows/ci.yml`): `forge fmt --check`, `forge build --sizes` (fail if the hook is within 2% of the limit), `forge test`, coverage gate, Slither.
- `README.md` must contain: what/why, architecture diagram, guarantees, quickstart, deployed addresses (with explorer links), simulation results table, known limitations and links to `docs/`.

---

## 11. Tooling and commands

Expected commands (create the scripts/targets if missing):
```bash
forge build --sizes                         # also checks contract size
forge fmt                                    # formatting (CI runs --check)
forge test -vvv                              # full test suite
forge test --match-path "test/unit/*"        # one layer
forge test --match-contract BallastInvariant # invariants
forge coverage --report lcov                 # coverage
forge snapshot                               # gas snapshot
slither . --config-file slither.config.json  # static analysis
```

Suggested `foundry.toml` (adjust after **VERIFY**):
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.26"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
bytecode_hash = "none"
fs_permissions = [{ access = "read-write", path = "./deployments" }, { access = "read", path = "./config" }]

[profile.default.fuzz]
runs = 1000

[profile.default.invariant]
runs = 256
depth = 128
fail_on_revert = false

[profile.ci.fuzz]
runs = 10000

[profile.ci.invariant]
runs = 1024
depth = 256

[fmt]
line_length = 100
tab_width = 4
bracket_spacing = false
```
If `via_ir` is needed for stack depth, enable it and write why in `docs/DECISIONS.md`.

---

## 12. Deployment and operations

**Scripts** (`script/`), all idempotent and reading `config/addresses.json`:
1. `DeployBallast.s.sol`: load config, mine a salt with our own `HookMiner` for the flags from `getHookPermissions()`, deploy the hook with CREATE2, **assert the address flags match**, deploy `BallastLens` and `SupplyCapAdvisor`, write `deployments/<chainId>.json`.
2. Pool initialization (static fee, tick spacing, starting price) happens in the same broadcast as the hook deployment, from the `initializer` account (ADR-014). `CreatePool.s.sol` is used for the control pool.
3. `SeedVaults.s.sol`: create two curator vaults with different bands/commitments and seed deposits.
4. `FundStandby.s.sol`: sponsor funds the standby pool and sets the rate.
5. `RunCrash.s.sol`: executes the scripted swap sequence against the Ballast pool and the control pool.
6. Verification: use `forge verify-contract` (or a `verify.sh` wrapper). Every deployed contract must be verified on the explorer.

**Testnet limits.** Public testnets cannot warp time. Provide a `DemoConfig` with compressed windows (minutes, not hours) for the live deployment, and a `ProdLikeConfig` used in Foundry scenario tests where time can be warped. State this clearly in the README so no one mistakes the demo parameters for recommended production values.

**Mock assets.** For the demo, deploy mock collateral and quote ERC-20s (and a simple swap router) unless the human chooses real testnet tokens (**OPEN Q-4**). Mocks live in `test/utils` and `script/mocks`, never in `src/`.

---

## 13. Evaluation and demo deliverables

What must exist and work (these are the Functionality evidence):
1. A verified deployment on the target testnet with addresses in the README and `deployments/<chainId>.json`.
2. A **control pool**: an ordinary v4 pool (no hook) with identical liquidity, used for comparison.
3. A scripted **crash**: price falls through the liquidation band. Measured on both pools: slippage on a liquidation-sized sell, depth remaining, whether LP exits were possible, LP token outcomes, time to recover.
4. **Lock behaviour**: an exit attempt during stress is rejected or deferred; after calm (or `maxStressLock`) it succeeds.
5. **Standby accrual and breach**: show reward crediting; show a coverage breach pausing accrual.
6. **Depth views over time**: `committedDepth`, `liveDepth`, `lockState`, and the `SupplyCapAdvisor` output before, during and after stress.
7. Results written to `analysis/results/*.json` and summarized in `docs/SIMULATION.md` with the pre-registered bar (§9.4).

Honesty rules for results: report what happened, including failures and limitations. Do not extrapolate to mainnet outcomes. Do not claim the lock protects depositors from price losses.

You do not write the live demo narration or pitch. You may write `docs/RUBRIC_MAP.md` as a facts-only checklist of where each rubric criterion is evidenced.

---

## 14. Rubric map (what the repo must show)

| Criterion | Evidence we need in the repo |
|---|---|
| **Original Idea** | README "what is new": stress-gated commitments plus an on-chain depth oracle for collateral risk. State that time-locked liquidity already exists, so the claim is the stress gate, the pool-wide committed depth and the lender-facing views. List precedent found and how we differ (`docs/ECONOMICS.md`). |
| **Unique Execution** | Minimal `getHookPermissions`; `BaseHook` usage; hook-only liquidity via callbacks; atomic re-range with flash accounting; PoolManager claims for idle custody; ERC-6909 shares; transient-storage guards; pure libraries; differential, fuzz and invariant tests; gas budgets; Slither report. |
| **Impact** | `docs/ECONOMICS.md` (who pays, why LPs accept the risk, pricing of tail liquidity as put-writing); Aave governance references; the advisor view; crash-simulation results versus the control pool. |
| **Functionality** | Verified deployment, manifest, passing CI, scenario tests, one-command demo scripts, README quickstart. |
| **Presentation** | Human-owned. Repo supports it with a clear README, diagrams and results tables. |

---

## 15. Milestones and definition of done

Build a thin vertical slice early, then deepen. Each milestone ends with green CI, updated docs and an ADR where decisions were made.

| # | Milestone | Done when |
|---|---|---|
| M0 | Scaffold | Repo layout, pinned deps, CI green on an empty hook, `foundry.toml`, address config, README stub |
| M1 | Maths libraries | `Observations`, `BandMath`, `DepthMath`, `StressMachine`, `VaultMath`, `RewardMath` with unit, fuzz and differential tests |
| M2 | Hook skeleton | `BallastHook` with permissions, pool binding, oracle writes, G-1 tests (external add/remove revert), CREATE2 mining test |
| M3 | Vault lifecycle | Create, deposit, request/claim/cancel redeem, proportional maths, fees crystallization, shares ledger; fuzz plus invariants INV-1…5 |
| M4 | Re-range and coverage | Atomic re-range, coverage rule, commitment changes, breach flow; INV-7 |
| M5 | Stress machine and gate | Lazy evaluation, lock, no re-arm, additive-only re-range in stress; INV-6, INV-12; Crash scenario |
| M6 | Standby fund | Funding, rate, checkpoint accrual, sniping tests, drought behaviour; INV-8 |
| M7 | Lens and advisor | Depth views, horizon netting, advisor; INV-9, INV-10 |
| M8 | Hardening | Full invariant suite, manipulation scenarios, Slither triage, gas snapshot, coverage gate |
| M9 | Deploy | Scripts, verified testnet deployment, manifest, fork tests |
| M10 | Simulation | Pre-registration committed, control-pool comparison run, results documented |
| M11 | Docs polish | `SPEC`, `ARCHITECTURE`, `MATH`, `THREAT_MODEL`, `ECONOMICS`, `TESTING`, `DEPLOYMENT`, `SIMULATION`, `RUBRIC_MAP`, `SECURITY`, README final |

**Cut list if time runs short (cut from the top, never touch G-1…G-6 or tests):** `SupplyCapAdvisor` extras, curator-record extras beyond counters, `cancelRedeem`, fork tests beyond smoke, ECONOMICS depth. Never cut: hook-only liquidity, proportional shares, stress lock, notice queue, coverage rule, standby accrual, committed/live depth views, invariants, the crash comparison.

---

## 16. Working agreement for Claude Code

**At the start of a session**
1. Read this file and any existing `docs/`. Run `git status`, `forge build`, `forge test` to learn the current state.
2. List any open questions (§17) that block the next task and ask them in one message.
3. State a short plan for the task and which milestone it belongs to.

**While working**
- Write tests first (or alongside) for libraries and invariants. Run the narrowest relevant tests often, the full suite before finishing.
- Read dependency source before using an API. If a **VERIFY** item turns out different from this file, tell the human and record an ADR instead of silently adapting.
- Keep diffs focused. Do not refactor unrelated code. Do not add dependencies without an ADR.
- If you discover a design flaw, a missing edge case or an inconsistency in this spec, **stop and report it with a proposed fix**. Do not patch around it.

**Before saying a task is done, check**
- [ ] `forge fmt`, `forge build --sizes`, `forge test` all pass; coverage did not regress.
- [ ] NatSpec, events and custom errors present; rounding directions documented.
- [ ] New behaviour has unit, fuzz and (where relevant) invariant tests.
- [ ] No weakened assertions, no skipped tests, no TODOs, no dead code.
- [ ] Docs and ADRs updated; guarantees G-1…G-6 and invariants INV-1…14 still hold.
- [ ] Nothing secret or machine-specific committed.

**Never**
- Invent addresses, ABIs, or numbers in results. Never fabricate simulation or gas figures. Run the thing or say it was not run.
- Make claims in docs that the code and tests do not support.
- Write presentation scripts for the human.

---

## 17. Open questions (ask the human)

| ID | Question | Why it matters |
|---|---|---|
| Q-1 | Is the name "Ballast" available (GitHub, X, hackathon page)? | Naming clash risk |
| Q-2 | License for our code (default MIT)? **Resolved: MIT.** | `LICENSE` and SPDX headers |
| Q-3 | Confirm target chain (Unichain Sepolia?) and which RPC/explorer to use **Resolved: chain 1301**, RPC and explorer in `config/addresses.json`. | Deployment scripts, fork tests |
| Q-4 | Demo assets: mocks or real testnet tokens? Collateral/quote decimals? **Resolved: mocks** (decimals still to choose). | Depth maths and demo realism |
| Q-5 | Pass/fail bar for the crash simulation | Pre-registration (§9.4) |
| Q-6 | Submission deadline | Decides the cut list |
| Q-7 | Confirm D-8 (standby fee paid in the quote currency) | Simplifies accounting but fixes the reward token |
| Q-8 | Curators permissionless, or sponsor-allowlisted for the demo? **Resolved: permissionless.** | Spam/abuse surface and the story |
| Q-9 | Should deposits be blocked in RECOVERING as well as STRESS? **Resolved: blocked in both.** | UX versus safety |

---

## 18. Documentation set

Draft versions of these documents exist in `docs/` (plus root `README.md` and `SECURITY.md`). Treat them as the detailed companions to this file and keep them in sync with the code:

| Document | Purpose |
|---|---|
| `docs/SPEC.md` | Normative requirements (`R-…` IDs), state availability table, edge cases |
| `docs/CONTRACTS.md` | Public surface: types, functions, access control, events, errors, libraries |
| `docs/ARCHITECTURE.md` | Diagrams, flows, custody model, storage plan, rationale |
| `docs/MATH.md` | Formulas, rounding directions, worked example, test tolerances |
| `docs/THREAT_MODEL.md` | Assets, attackers, threats T1–T18, residual risks, audit checklist |
| `docs/VERIFICATION.md` | Evidence for every VERIFY item (file and line or URL) and its design impact |
| `docs/TESTING.md` | Test layers, invariants, bars, compliance matrix, gas budgets |
| `docs/ECONOMICS.md` | Who pays and earns, put-writing framing, pricing framework (no numbers until measured) |
| `docs/DEPLOYMENT.md` | Config profiles, scripts, smoke tests, manifest, release checklist |
| `docs/SIMULATION.md` | Evaluation protocol, scenarios, pre-registration, results template |
| `docs/RUBRIC_MAP.md` | Facts-only rubric evidence checklist |
| `docs/DECISIONS.md` | ADR log (append-only) |
| `README.md`, `SECURITY.md` | Public overview and security policy |

Precedence for detail: `docs/SPEC.md` and `docs/CONTRACTS.md` win over §6 of this file. This file wins on scope and process. If you find an inconsistency, report it with a proposed fix; do not silently pick a side. As each milestone completes, update the affected docs and mark resolved VERIFY items in `docs/DECISIONS.md`. Generate `docs/COMPLIANCE.md` (requirement → tests) and `docs/storage-layout.md` (from `forge inspect`) once code exists.

---

## 19. Glossary

- **Collateral / quote:** the asset liquidators sell into the pool / the asset they receive.
- **Liquidation direction:** the price direction caused by selling collateral into the pool (ticks fall if collateral is currency0, rise if currency1).
- **Anchor:** TWAP over `anchorWindow`; the reference price for the band.
- **Band:** price interval from the anchor to anchor × (1 − X) in the liquidation direction.
- **Committed depth:** collateral the vaults' ranges can absorb inside the band; static in spot price.
- **Live depth:** collateral the pool can absorb from the current spot down X, net of maturing exits.
- **Stress / lock:** state in which the short TWAP is far from the anchor in the liquidation direction; exits are frozen up to `maxStressLock`.
- **Standby fee:** sponsor-paid reward per second per unit of verified committed depth.
- **Coverage:** `committedDepth_v ≥ commitment_v`.
- **Idle:** undeployed vault balances, held as PoolManager claims and shared pro rata.
- **Proportional in-kind shares:** shares denote a fraction of the vault's liquidity and idle balances; no NAV or price is used to mint or redeem.
- **Flash accounting:** v4's transient delta ledger; only net balances settle when the unlock ends.
