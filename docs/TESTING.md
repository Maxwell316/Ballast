# Ballast Testing Strategy

**Status:** Draft v0.1 · The test suite is a primary deliverable. It proves the guarantees in [SPEC](SPEC.md) and demonstrates the behaviour described in [SIMULATION](SIMULATION.md).

---

## 1. Principles

1. Every requirement (`R-…`) and invariant (`INV-…`) maps to at least one test (§6).
2. Tests are deterministic: no wall-clock time, no network outside `test/fork/`, no ordering dependence.
3. Failures indicate a defect in code or spec. Never weaken an assertion to make a test pass.
4. Property tests are bounded deliberately; do not discard most runs with `vm.assume`.
5. Readable scenario tests double as documentation of behaviour.

## 2. Layout

```
test/
├── unit/        BallastHook.*.t.sol, BallastLens.t.sol, SupplyCapAdvisor.t.sol, libraries/*.t.sol
├── fuzz/        VaultMath.fuzz.t.sol, DepthMath.fuzz.t.sol, BandMath.fuzz.t.sol, RewardMath.fuzz.t.sol,
│                StressMachine.fuzz.t.sol, Observations.fuzz.t.sol, Differential*.t.sol
├── invariant/   BallastInvariant.t.sol, handlers/*.sol, ghosts/*.sol
├── scenario/    Crash.t.sol, Breach.t.sol, Drought.t.sol, Manipulation.t.sol, Control.t.sol
├── fork/        Deployed.t.sol (skips without RPC)
├── gas/         GasBudget.t.sol
└── utils/       BaseFixture.sol, MockERC20.sol, MockRouter.sol, Actors.sol, Attackers.sol (reentrancy, callbacks)
```

## 3. Layers

### 3.1 Unit
- One test file per function group. Cover success and every revert path with `vm.expectRevert(abi.encodeWithSelector(...))`.
- Naming: `test_<Function>_<Behaviour>()` and `test_RevertWhen_<Condition>()`.
- Tag tests with NatSpec `@custom:requirement R-LIQ-1` so the compliance matrix can be generated.

### 3.2 Fuzz
| Target | Properties |
|---|---|
| `VaultMath` | Round trip never favours the actor; monotonic in shares; no overflow in bounds |
| `DepthMath` | Non-negative; zero when overlap is empty; additive over disjoint overlaps; monotonic in liquidity and in band width |
| `BandMath` | `bpsToTicksDown` monotonic; within 1 tick of reference; edges ordered correctly for both collateral directions |
| `RewardMath` | Exact floor against a 512-bit reference; never exceeds `eligible · interval · rate / scale` |
| `StressMachine` | Only legal transitions; hysteresis; lock cannot re-arm before CALM; expiry at `maxStressLock` |
| `Observations` | Running accumulator exact at every swap and at snapshot times; interpolation exact when no swap lies between snapshots, and within `observationInterval × Δτ_max / window` otherwise (MATH §4), with adversarial intra-interval swap patterns; TWAP rounding toward −∞; warm iff the anchor window is covered |

### 3.3 Differential
- **Depth vs swaps:** build a pool with known liquidity; swap collateral in increasing steps until price reaches the band edge; the measured input net of fee MUST be ≥ `DepthMath` output and within the documented rounding bound.
- **Oracle vs model:** a naive Solidity model recomputes TWAP from the full tick history, including swaps that fall between snapshots; the error bound of MATH §4 is asserted.
- **Stress vs table:** a table-driven reference of `(state, dev, time) → (state)`.

### 3.4 Invariant
Handler-based. Actors: three curators, five depositors, one sponsor, one trader, one time-warper.

Handler actions (each bounded and guarded to avoid trivially reverting calls):
`createVault`, `seed` (curator), `deposit`, `requestRedeem`, `cancelRedeem`, `claimRedeem` (owner and operator, arbitrary receiver), `rerange` (calm), `deployIdle`, `setCommitment`, `checkpoint`, `pokeStress`, `fundStandby`, `setStandbyRate`, `swapCollateralIn`, `swapQuoteIn` (various sizes), `warp`.

Ghost variables: total deposited and withdrawn per currency, total credited rewards, total funded, per-vault shares, number of lock violations (must stay zero), observed state transitions.

Invariants implemented: INV-1 … INV-12, INV-14 and INV-15 (warm is monotonic) (see CLAUDE.md §8.2). INV-3 is the inequality form (claims held ≥ Σ idle + curatorOwed + standby fund, per currency) plus a ghost ledger of PoolManager-reported deltas for principal, with dust always in the vault's favour. INV-13 is **not** a runtime invariant: it is a static access-control test that enumerates every external selector of the hook and asserts the expected callers (§3.7). Use `fail_on_revert = false`, and assert in handlers that expected reverts are the expected errors.

### 3.5 Scenario
| Test | Narrative | Asserts |
|---|---|---|
| `Crash` | Price falls through the band; lock engages; liquidation-sized sell executes; exits blocked; market recovers; exits clear | Lock timing, no exit during lock, depth views over time, post-crash redeem succeeds |
| `Breach` | Anchor drift breaks coverage; grace; flag; accrual pauses; curator restores | Breach flow, record counters, accrual resumes |
| `Drought` | Sponsor stops funding | Accrual stops; `StandbyDepleted` once; depth views decay as exits mature |
| `Manipulation` | Attacker tries T3, T4, T5, T6 | Mitigations hold; attacker cost recorded |
| `Control` | Same liquidity in a plain pool vs Ballast under the same shock | Metrics feed SIMULATION |
| `ExitRace` | Matured tickets exist when a crash begins; holders claim as early as the machine allows | Quantifies matured-ticket liquidity that exits before the lock engages, for stated parameters (T18); no claim after the lock engages |

### 3.7 Static access control (INV-13)
A test enumerates every external and public selector of `BallastHook` (from the ABI) and maps each to its expected caller class (anyone, curator, sponsor, ticket owner or operator, PoolManager). For each selector it calls from every other class and asserts the revert. A new selector without an entry fails the test. This is also an audit checklist item.

### 3.6 Fork
Run key flows on the target chain's PoolManager at a pinned block. Skip with a clear message if `RPC_URL` is unset. Purpose: catch deployment-specific differences (hook flag bit order, token behaviour, PositionManager interaction). `test/fork/HooksOnChain.t.sol` is the first fork test: a test hook carrying Ballast's five flags is placed with `deployCodeTo` on a fork of the Unichain Sepolia PoolManager and shows every callback firing, external liquidity changes blocked while the hook's own succeed, and claims-based settlement (docs/VERIFICATION.md F-3). Run: `RPC_URL=https://sepolia.unichain.org forge test --match-contract HooksOnChainTest`.

## 4. Bars

| Bar | Requirement |
|---|---|
| Line coverage | ≥ 95% on `src/` (excluding mocks) |
| Branch coverage | ≥ 90% |
| Fuzz | 1,000 runs local, 10,000 in CI profile |
| Invariants | ≥ 256 runs × depth 128 local; 1,024 × 256 in CI |
| Static analysis | Slither clean or each finding justified in `docs/SLITHER_NOTES.md` |
| Formatting | `forge fmt --check` |
| Size | `forge build --sizes`: hook below limit with ≥ 2% margin |

## 4a. Library test conventions (M1 onwards)
- **Decimals and ordering matrix.** The default fixture is collateral 18 decimals and quote 6. Library and differential tests also run (a) collateral 6 and quote 18, (b) equal decimals, and (c) both currency orderings (collateral as currency0 and as currency1). Every band and depth test covers both collateral directions. The start tick for a 1:1 human price is derived from the decimals (see `test/utils/Scenario.sol`).
- **Requirement tags.** Every test carries `@custom:requirement R-…` (and `@custom:invariant INV-n` where relevant). `tools/compliance.py` reads them and reports which SPEC requirements have no test (`docs/COMPLIANCE.md`). It reports only, until the suite is complete.
- **Coverage gate.** The gate covers all of `src/` (≥ 95% lines, ≥ 90% branches) from the end of M2. CI runs the instrumented coverage with the default (not the CI) fuzz profile.
- **Mutation sanity check.** After each library's tests pass, a scratch change breaks its rounding direction, bounds or comparison and at least one test must fail; the mutations tried and the tests that caught them are recorded in the milestone report. Scratch changes are reverted.
- **Gas.** `test/gas/` measures each oracle path with cold storage and records them in `.gas-snapshot` and in this document. `beforeSwap` may do only the O(1) accumulator update plus at most one snapshot write per interval; the binary search runs only on the evaluation path and in views.

## 5. Test data and fixtures

`BaseFixture` deploys: PoolManager (or uses a canonical fixture), mock collateral and quote tokens, the hook at a mined address, two curators with different bands, initial deposits, a sponsor with a funded standby pool, and a router. Provide helper functions: `warpAndSwap`, `driveTwap(deviationTicks, duration)`, `crashTo(percent, duration)`, `liquidationSell(amount)`. Parameter profiles: `ProdLike` (hours) and `Compressed` (minutes) for demo parity tests.

## 6. Compliance matrix

Generate `docs/COMPLIANCE.md` from test NatSpec tags in CI. Format:

| Requirement | Tests |
|---|---|
| R-POOL-1 | `test_beforeInitialize_BindsFirstPool`, `test_RevertWhen_SecondPoolInitialized` |
| R-LIQ-1 | `test_RevertWhen_PositionManagerAddsLiquidity`, `test_RevertWhen_RouterAddsLiquidity` |
| … | … |

CI fails if any `R-` identifier in SPEC has no test.

## 7. Gas budgets

Targets (measure, record in `.gas-snapshot`, justify regressions above 5%):

| Path | Target |
|---|---|
| `beforeSwap`, no write, no stress evaluation | < 30k |
| `beforeSwap`, write and evaluation | < 80k |
| `deposit` (2 positions) | < 500k |
| `requestRedeem` | < 120k |
| `claimRedeem` (2 positions) | < 450k |
| `rerange` (2 → 2) | < 700k |
| `committedDepth()` worst case, `view` | record |

### Oracle gas, measured (M1; `test/gas/ObservationsGas.t.sol`, cold storage, internal to the library call, forge 1.8.4)

| Path | Gas | Note |
|---|---|---|
| `update`, same timestamp (no-op) | 2,462 | |
| `update`, accumulate only | 6,459 | the per-swap hot path when no snapshot is due |
| `update`, accumulate + snapshot overwrite (ring full) | 14,212 | steady state, at most once per `observationInterval` |
| `update`, accumulate + snapshot push (ring filling) | 34,029 | first `cardinality` snapshots only |
| `cumulativeNow` | 2,745 | |
| `twapTick`, 24 h window, full ring (1,585 slots) | 44,037 | binary search |
| `twapTick`, 15 min window, full ring | 40,874 | binary search |

### `beforeSwap` gas, measured through `PoolManager.swap` (M2; `test/gas/BeforeSwapGas.t.sol`, ADR-038)
Gas inside `_beforeSwap` (probe in the test-only harness), storage cold (`vm.cool`), forge 1.8.4, cardinality 1,585, interval 60 s, 24 h anchor window.

| Path | Before cursors | With cursors | Budget |
|---|---|---|---|
| same timestamp as the last swap (no update) | 4.7k | 4.7k | < 30k |
| update only (new timestamp, no snapshot due) | 8.7k | 8.7k | < 30k |
| update + snapshot + evaluation, cold oracle (anchor window not covered) | 52k | 51k | < 80k |
| update + snapshot (push) + evaluation, warm, ring still filling | 113k | **85k** | ≤ 90k (first `cardinality` snapshots only, about 26 h at defaults) |
| update + snapshot (overwrite) + evaluation, warm, wrapped ring (steady state) | 97k | **68k** | < 80k |

Library level (`test/fuzz/ObservationsCursor.t.sol`): one 24 h-window lookup on a full ring costs 41.9k with binary search and 17.8k from a cursor one interval later. Budget amended from the original "< 80k with write and evaluation" to the two rows above (ADR-038). The `BallastHook` runtime size is 13.5 kB of 24.6 kB.

## 7a. M2 test inventory
| Suite | What it proves |
|---|---|
| `unit/hook/HookCallbacks` (22) | init restrictions (non-initializer, wrong fee, wrong spacing, dynamic fee, native currency0 and currency1, wrong pair, hooks field, second init, non-PoolManager caller), binding, collateral side both orderings, oracle seed, G-1 add/remove/poke through a plain router, hook self-call bypass, donate, mined CREATE2 address, flags equal permissions |
| `unit/hook/OracleThroughSwaps` (6) | same-timestamp double swap accumulates once, in-block round trip has no weight, sparse swaps exact, fuzzed real-swap history vs the naive model (accumulator, every snapshot, increasing timestamps, TWAP bound over the true bracket), adversarial swap timing (non-vacuous: error > 0 and within bound), cold to warm |
| `unit/hook/StressEvaluation` (9) | cold oracle stays CALM, lazy evaluation and pure-preview views, full episode with each event once, lock expiry once and no re-arm and new episode after CALM, collateral as currency1 mirrored, no stress against the liquidation direction, evaluation once per interval, permissionless poke |
| `unit/hook/TransientGuards` (9) | swap-then-vault-op and vault-op-then-swap revert (single transaction), flags do not outlive a transaction, lock released, reentrancy reverts, probe that tests are separate transactions |
| `invariant/BeforeSwapTotality` (3) | R-STR-10: 256 runs x 128 calls (32,768) plus 300 fuzz sequences over starting pools: `beforeSwap`, `pokeStress` and views never revert; only legal transitions; view equals stored state after a poke |
| `scenario/LiquidationDuringStress` (4) | a liquidation-sized sell executes in STRESS, RECOVERING, after expiry and in the evaluating transaction |
| `fuzz/ObservationsCursor` (7) | hinted lookup equals binary search across fuzzed histories with wraparound, gaps, garbage and stale cursors; cursor is much cheaper |
| `fuzz/StressMachineVectors` (1) | second, SPEC-only reference: 300 timelines, 10,410 evaluation points, 0 disagreements |
| `fork/HookOnlyLiquidityFork` (5), `fork/DeployBallastScript` (1) | real PositionManager and deployed routers cannot add/remove; hook self-call works; swap through the deployed router writes the oracle; the real deployment script on a fork |

Test-only code: `test/utils/BallastHookHarness.sol` (subclass exposing the guards, the hook's own liquidity entry points and a gas probe) never enters `src/` (ADR-044).

## 7b. Aliasing review (M2)
Searched `src/` and `test/` for memory-struct assignments and storage-to-memory copies assumed independent. Findings: (1) `Observations.cumulativeAtHinted`: `next = hint` aliased the caller's cursor; harmless today (nobody mutates it) but fragile; now an explicit copy. (2) `test/fuzz/StressMachine.fuzz.t.sol::_ref`: `o = r` aliased the reference model's input and mutated it in place; benign in the current branch order but the same class as the `nc = c` bug; now an explicit copy, all fuzz tests still pass. (3) Storage-to-memory copies (`StressStorage memory st = _stress`, `Observations.State memory st = s`, `PoolKey memory k = key` in tests) are genuine copies in Solidity and are independent; the writes back are field by field. No other hazards. Rule for M3 onwards: never assign one memory struct to another; construct a new one.

## 8. Requirement-to-test starter map

| Area | Must-have tests |
|---|---|
| Pool binding | first pool binds; second reverts; non-initializer reverts `PoolInitializerOnly`; fee or tickSpacing mismatch reverts; dynamic fee reverts; native reverts; wrong currencies revert |
| Liquidity ownership | PositionManager add/remove revert; router add/remove revert; hook self-call works |
| Oracle | accumulator exact across sparse swaps; swaps inside one snapshot interval stay exact in the accumulator; same-block double swap accumulates once; interpolation error within the MATH §4 bound; cold start warm flag (anchor window) |
| Stress | enter, recover, exit, relapse; relapse does not reset `stressStartedAt`; lock expiry; no re-arm; cold pool stays CALM; `claimRedeem` releases an expired lock without a poke; view preview equals executed transition |
| Vaults | create/seed/deposit/redeem round trip; seed by non-curator reverts, receiver may differ; notice enforcement; lock blocks claim; claim by owner and by operator to any receiver; non-owner reverts; cancel returns shares; no poke of a zero-liquidity position |
| Re-range | calm success; coverage failure reverts; stress reverts; idle remainder preserved |
| Standby | accrual; fund cap; breach stops; reward shrinks as a crash consumes liquidity (`Λ_v`); depletion event once; sniping unprofitable |
| Fees | crystallization separates `feesAccrued`; curator cut on fees and rewards only |
| Views | committed vs live depth; horizon netting; lock-aware netting; bounded gas |
| Guards | swap then vault op reverts and vault op then swap reverts, for each of seed, deposit, claimRedeem, rerange and deployIdle; reentrancy attacker fails |
| Deployment | address flags equal permissions; hook deployed and pool initialized in one broadcast; script idempotent |

## 9. CI pipeline

`.github/workflows/ci.yml` runs: checkout with submodules, install Foundry, `forge fmt --check`, `forge build --sizes`, `forge test` (CI profile), `forge coverage` with threshold check, Slither, and compliance-matrix generation. Fork tests run on a schedule or manual dispatch if an RPC secret exists.

## 10. G-1 and split-architecture tests (ADR-045, ADR-050)

- **G-1 (local):** `unit/hook/LiquidityGate` and `unit/hook/HookCallbacks`: plain router add, remove and zero-liquidity poke; an arbitrary contract that unlocks then calls `modifyLiquidity` (add, remove, poke); the hook itself as caller. All revert with `ExternalLiquidityForbidden`.
- **G-1 (fork of chain 1301, block 68,788,256):** `fork/HookOnlyLiquidityFork`: the real PositionManager (mint into an empty and into an occupied range) and the deployed routers (add, remove, poke) fail; the vaults' own liquidity succeeds and is owned by the vaults (INV-1).
- **T19:** `LiquidityGateTest` checks the compiled ABI, the runtime selectors for `unlock`/`unlockCallback` (with controls in the vaults' code) and, behaviourally, that every outgoing call of the hook over swaps, a poke and a vault operation is a PoolManager storage read. A literal `modifyLiquidity` scan is not used as proof: the optimizer builds some selector constants arithmetically (ADR-050 note).
- **Sizes:** `unit/Sizes`: every runtime is at most 23,800 bytes except the vaults (at most 24,300 with at least 250 bytes of margin, ADR-051); every initcode plus its largest constructor arguments is at most 46,152 bytes (the EIP-3860 limit minus 3,000).
- **Layout:** `unit/lens/LensLayout`: every field the lens decodes through `extsload` equals the vaults' own state after each step of a multi-vault lifecycle.
- **Gate mutation sanity:** `sender == vaults` changed to `!=`, and the check removed; both fail the G-1 tests (see MUTATION_LOG.md).
- **Deployment:** `fork/DeployBallastScript` runs the real script on the fork: CREATE2 hook address flags, both binding directions, `VerifyBinding`, pool initialised.
- **Time in tests:** read time with `vm.getBlockTimestamp()`, never `block.timestamp` (ADR-054).
