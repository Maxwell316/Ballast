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
Added in M8: `roundTrip` (deposit then immediate redeem, INV-5), `mixedTx` (a swap and a vault operation in one transaction through a `TxMixer`, INV-14) and `donate` (tokens, claims and shares sent to the hook and vaults, T2).

The suite is a `Matrix` base with two leaves, `C0Before` and `C1After` (collateral ordering x lens construction order, ADR-059). It runs about 137 s per leaf locally at 256 x 128; the CI profile (1024 x 256) is correspondingly slow, so coverage runs use the `coverage` profile and only one variant per ordering. INV-9 is checked by sampled brute force inside a snapshot.

Ghost variables: total deposited and withdrawn per currency, total credited rewards, total funded, per-vault shares, number of lock violations (must stay zero), observed state transitions.

Invariants implemented: INV-1 … INV-12, INV-14 and INV-15 (warm is monotonic) (see CLAUDE.md §8.2). INV-3 is the inequality form (claims held ≥ Σ idle + curatorOwed + standby fund, per currency) plus a ghost ledger of PoolManager-reported deltas for principal, with dust always in the vault's favour. INV-13 is **not** a runtime invariant: it is a static access-control test that enumerates every external selector of the hook and asserts the expected callers (§3.7). Use `fail_on_revert = false`, and assert in handlers that expected reverts are the expected errors.

### 3.5 Scenario
| Test | Narrative | Asserts |
|---|---|---|
| `Crash` | Price falls through the band; lock engages; liquidation-sized sell executes; exits blocked; market recovers; exits clear | Lock timing, no exit during lock, depth views over time, post-crash redeem succeeds |
| `Breach` | Anchor drift breaks coverage; grace; flag; accrual pauses; curator restores | Breach flow, record counters, accrual resumes; both currency orderings and lens construction orders |
| `Drought` | Sponsor fund is exhausted; an exit ticket approaches maturity and is claimed | Accrual stops; `StandbyDepleted` once; depth views net exits before and after the notice horizon; both currency orderings and lens construction orders |
| `Manipulation` | Attacker tries T3, T4, T5, T6 | Mitigations hold; attacker cost recorded |
| `Control` | Same liquidity in a plain pool vs Ballast under the same shock | Metrics feed SIMULATION |
| `ExitRace` | Matured tickets exist when a crash begins; holders claim as early as the machine allows | Quantifies matured-ticket liquidity that exits before the lock engages, for stated parameters (T18); no claim after the lock engages |

### 3.7 Static access control (INV-13)
A test enumerates every external and public selector of `BallastHook` (from the ABI) and maps each to its expected caller class (anyone, curator, sponsor, ticket owner or operator, PoolManager). For each selector it calls from every other class and asserts the revert. A new selector without an entry fails the test. This is also an audit checklist item.

The current implementation classifies every production selector in `AccessControl.t.sol` and behaviorally
checks the restricted classes (PoolManager callbacks, vault-only custody helpers, sponsor functions, curator
functions, ticket ownership, and permissionless calls). The selector list is an allowlist, not proof by itself
that every caller class was tried against every selector; the explicit negative-call tests are the behavior
evidence. The mutation check records representative removed curator and sponsor guards.

### 3.8 Lens independence audit (INV-9)

For each depth assertion, the test's expected value must come from a source independent of the lens, vaults, and
the same depth-math implementation on the same inputs. This table records the source used by the high-risk view
checks; the broader per-test review is recorded in the table immediately below.

| Surface | Independent evidence | What it establishes |
|---|---|---|
| `DepthMath` and `BallastDepth` | Real swaps in a separate plain PoolManager pool; committed tick-reference vectors | Conservative absorbable collateral and documented rounding tolerance |
| `BallastLens.liveDepth` and `committedDepth` | `LensDifferential` and `BallastInvariant` compare against plain-pool swaps; invariant netting derives exiting shares from the share-token escrow | Both lens views do not overstate live or committed depth, including exits and breaches |
| Exit netting | Closed-form share ratios, exact horizon boundaries, and share-token escrow; mutation tests remove netting or change its rounding | Maturing exits reduce risk-consumer depth with conservative rounding |
| `SupplyCapAdvisor` | `SupplyCapAdvisor.t.sol` pins the underlying depth to the external vector and plain-pool swap before checking multiplication | Advisor output uses `liveDepth`, not a lens-derived expected value |
| `Crash` depth assertions | Fixed far-edge before/after comparison, closed-form net sale and a plain-pool swap for the initial depth | Consumed collateral changes depth to a fixed edge by the measured sale amount |
| Storage decoded by the lens | `LensLayout` compares decoded values to the vaults test harness | Lens storage offsets and field interpretation stay in sync |

`LensDifferential` exercises six order/decimal/constructor-order variants; the handler-based INV-9 check exercises
those same dimensions and samples a plain-pool differential during invariant sequences. Swap measurements are the
behavioral reference and reference vectors are the absolute arithmetic check; a comparison of the lens to
`DepthMath` alone is not treated as depth correctness evidence.

### 3.9 Pool currency-order audit

The order-sensitive code was searched for assumptions about collateral being `currency0` or `currency1`. The
hook and lens derive the direction from sorted currency addresses; `BallastHook._beforeInitialize` validates the
sorted pair, while `BallastLens` derives the same immutable direction from the configured collateral and quote.
The deployment script deliberately sorts mock-token deployment order so collateral is `currency0`, but this is a
deployment convenience rather than a contract requirement. Tests in `HookCallbacks`, `Matrix`,
`LensDifferential`, `LensDepth`, `Crash`, and the invariant matrix exercise collateral in both positions. Any new
price-direction or token-delta logic must use the matrix helpers and keep both orderings in its tests.

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
| `deposit` (2 positions) | < 650k (measured 593,603; was 500k, ADR-057) |
| `requestRedeem` | < 200k (measured 159,088; was 120k) |
| `claimRedeem` (2 positions) | < 650k (measured 590,811; was 450k) |
| `rerange` (2 → 2) | < 800k (measured 731,446; was 700k) |
| `checkpoint` (2 positions, rate set) | < 500k (measured 436,716) |
| `setCommitment` | < 500k (measured 441,951: it runs a full checkpoint) |
| `committedDepth()` worst case (16 vaults × 8 positions), `view` | measured 1,180,177 gas |
| `liveDepth()` worst case (16 vaults × 8 positions), `view` | measured 1,736,575 gas |

The vault figures come from `test/gas/VaultGas.t.sol` (funded standby with a nonzero rate; cold storage; forge 1.8.4, `via_ir`, `optimizer_runs = 200`) and are asserted there.

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

## 7a2. M3-M6 test inventory (vaults, stress gate, standby; ADR-050..057)
| Suite | What it proves |
|---|---|
| `unit/vaults/VaultLifecycle` (17) | create validation (fee cap, ranges, duplicates, position and vault limits), seed (shares, burned minimum, pool ownership INV-1/2, curator-only, once, slippage), proportional deposit (exact payment, preview), exit queue (escrow, maturity, arbitrary receiver, operator, cancel, escrowed shares not transferable), INV-5 fuzz (a deposit-redeem round trip never profits and never shrinks the vault), donations to the vaults and the PoolManager do not move share maths (T2), trading-fee crystallization with the curator cut, no fee sniping |
| `unit/vaults/VaultRerangeCoverage` (13) | atomic re-range (liquidity moves, net to idle), same-range dust rule (minimal shrink, bounded idle drift), shortfall that is not dust reverts and leaves the vault untouched (ADR-055), growth from idle, invalid caller/input/unseeded, commitment increase immediate and decrease after the notice, increase cancels a pending decrease, breach (grace clock, flag, once per episode, exclusion from `committedDepth`, clearing by lowering the commitment or by a re-range), curator-record seconds |
| `unit/vaults/VaultStressOps` (7) | `deployIdle` (idle only, new position, same range reuses the slot, never reduces liquidity in stress, limits, `InsufficientIdle`), coverage not enforced under stress with a fresh grace after calm (R-COV-4), `liveDepth` monotone in the horizon and bounded by the pool's absorbable depth (INV-10) in CALM and STRESS (1,000 runs each) |
| `unit/vaults/StandbyAccrual` (10) | funding (claims held by the standby), sponsor-only and rate bound, vaults-only `accrue`, reward = floor(min(depth, commitment) x rate x dt / 1e18) with curator cut, interval cap, drought (rate 0), fund cap and `StandbyDepleted` once, pause during breach and resume, no sniping (deposit then exit gains nothing), re-range accrues on the smaller sample |
| `scenario/Crash` (8) | stress blocks claims, deposits, seeds and re-ranges but not requests, cancels, checkpoints, commitments or fee claims; RECOVERING still locks; calm releases with no poke; `maxStressLock` releases exits even if not calm (G-3); a liquidation executes in stress and depth falls while the lock holds; the exit race at crash onset (T18) is quantified (a matured 10% ticket leaves before the lock engages, then the next exit is refused); `lockedUntil` bound; horizon netting around the lock |
| `invariant/BallastInvariant` (6 + 1) | 256 runs x 128 calls on 12 actions (deposit, request, cancel, claim, re-range, commitment, checkpoint, swap, crash, warp, fund, rate): INV-1/2 positions owned by the vaults and equal to the pool, INV-3 claims cover idle, owed and fund, INV-4 supply equals balances, INV-6 no exit while locked, INV-12 legal transitions and no re-arming, INV-8 credited never exceeds funded; a scripted reachability test proves the handler reaches stress, a refused exit and a release after calm |
| `unit/lens/LensLayout`, `unit/lens/SupplyCapAdvisor` | the lens decodes the vaults' storage exactly (ADR-050); the advisor is `multiplier x liveDepth` and falls with exits inside the horizon |
| `unit/AccessControl` (10) | INV-13: every external selector of every contract is classified (new functions fail the test), no owner/pause/upgrade/withdraw-like name exists, every restricted function rejects a stranger with the expected error |
| `unit/hook/LiquidityGate`, `unit/Sizes`, `fuzz/BallastDepthDifferential`, `gas/VaultGas` | G-1 locally and T19, size bounds, the depth contract equals the library, vault gas budgets (ADR-057) |

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

`.github/workflows/ci.yml` runs: checkout with submodules, install Foundry, `forge fmt --check`, `forge build --sizes --skip "test/**" --skip "script/**"` (the test-only `BallastVaultsHarness` exceeds EIP-170 by design and is excluded; `unit/Sizes` is the enforced gate), `forge test` (CI profile), `forge coverage` with threshold check, Slither, and compliance-matrix generation. Fork tests run on a schedule or manual dispatch if an RPC secret exists.

## 10. G-1 and split-architecture tests (ADR-045, ADR-050)

- **G-1 (local):** `unit/hook/LiquidityGate` and `unit/hook/HookCallbacks`: plain router add, remove and zero-liquidity poke; an arbitrary contract that unlocks then calls `modifyLiquidity` (add, remove, poke); the hook itself as caller. All revert with `ExternalLiquidityForbidden`.
- **G-1 (fork of chain 1301, block 68,788,256):** `fork/HookOnlyLiquidityFork`: the real PositionManager (mint into an empty and into an occupied range) and the deployed routers (add, remove, poke) fail; the vaults' own liquidity succeeds and is owned by the vaults (INV-1).
- **T19:** `LiquidityGateTest` checks the compiled ABI, the runtime selectors for `unlock`/`unlockCallback` (with controls in the vaults' code) and, behaviourally, that every outgoing call of the hook over swaps, a poke and a vault operation is a PoolManager storage read. A literal `modifyLiquidity` scan is not used as proof: the optimizer builds some selector constants arithmetically (ADR-050 note).
- **Sizes:** `unit/Sizes`: every runtime is at most 23,800 bytes except the vaults (at most 24,300 with at least 250 bytes of margin, ADR-051); every initcode plus its largest constructor arguments is at most 46,152 bytes (the EIP-3860 limit minus 3,000).
- **Layout:** `unit/lens/LensLayout`: every field the lens decodes through `extsload` equals the vaults' own state after each step of a multi-vault lifecycle.
- **Gate mutation sanity:** `sender == vaults` changed to `!=`, and the check removed; both fail the G-1 tests (see MUTATION_LOG.md).
- **Deployment:** `fork/DeployBallastScript` runs the real script on the fork: CREATE2 hook address flags, both binding directions, `VerifyBinding`, pool initialised.
- **Time in tests:** read time with `vm.getBlockTimestamp()`, never `block.timestamp` (ADR-054).

## Lens, depth and standby independence audit (M8, 2026-11-27)

Rule: a test about depth passes only if its expected value does not come from the lens, the vaults or the same library on the same inputs. Acceptable sources: **swap** (a real swap through a plain, hookless v4 pool holding the same positions, `test/utils/BruteForce.sol`), **closed form** (arithmetic written in the test, including the off-chain 70-digit vector `397164717108464068` for 1e19 over [-6000, 6000], 779 ticks), **vector** (a committed reference file), **execution** (the tokens a real call moved), **constant** (an input the test chose). The verdict is for the test as found; "fixed" says what replaced a weak source.

| Test | Expected-value source (as found) | Verdict | Action |
|---|---|---|---|
| `BallastDepthDifferential.testFuzz_Measure_EqualsLibrary` | the same `DepthMath`/`BandMath` calls on the same inputs | **weak** as depth evidence (it proves the wrapper contract adds nothing) | kept as a wrapper-equivalence test, relabelled; depth evidence now comes from `LensDifferential` (which also holds `vaults.depthCalc` to brute force) and `DifferentialDepthMath` |
| `BallastDepthDifferential` shrink-liquidity tests | closed form written in the test | ok | none |
| `DifferentialDepthMath` (grid and fuzz) | swap, both orderings, decimals, LP fee, protocol fee | ok | none (library level) |
| `DepthMath.t.sol` worked examples | off-chain reference constants | ok | none |
| `DepthMath.t.sol` properties (monotone, additive) | relations between library calls | property only | none; absolute correctness is the two rows above |
| `StandbySampling.UsesTheSmallestSample` | `lens.poolAbsorbable` and `lens.vaultDepth`, then `RewardMath.accrue` | **weak** (lens and library as their own oracle) | **fixed**: swap through a plain pool for the live and the anchor sample, closed-form reward `depth x s x rate / 1e18`, both orderings, both lens construction orders |
| `EdgeCases.Lens_CommittedDepth_IsMinOfDepthAndCommitment` | `lens.vaultDepth(low)` | **weak** | **fixed**, moved to `LensDepth.t.sol`: closed-form vector, both orderings |
| `EdgeCases.Lens_Unseeded...` | constants (zero) | ok | moved to `LensDepth.t.sol` |
| `SupplyCapAdvisor.IsMultiplierTimesLiveDepth` | `lens.liveDepth` (for the depth), multiplication (for the advisor) | depth: **weak**; advisor logic: ok | **fixed**: the depth is held to the vector and a swap, then the multiplication |
| `SupplyCapAdvisor.FallsWhenExitsMature` | closed-form ratio, 1% tolerance | ok but loose | **tightened** to the wei against the vector |
| `StandbyAccrual.*` | constants (commitment binds), the literal `3e13`, `RewardMath.accrue` | mostly ok; `RewardMath` as oracle in 3 places | **fixed**: closed-form reward; drought assertion held to the vector; both orderings (`_quoteIdle` was hard-wired to currency1) |
| `VaultStressOps` INV-10 fuzz | `lens.liveDepth` against `lens.liveDepth` and `lens.poolAbsorbable` | self-consistency (properties of one view) | kept; absolute correctness and exit netting are in `LensDifferential`; both orderings added |
| `VaultRerangeCoverage` depth uses | constants `COVERED`, `UNCOVERED` against the depth; one range check `3.9e17 < d < 4.0e17` | ok; the range check was loose | **tightened** to the vector; both orderings added |
| `Crash.test_Liquidation...` | constants; `lens.poolAbsorbable` only for `> LIQUIDATION` | ok | both orderings added; direction-aware price assertion |
| `Crash.test_LiveDepth_NetsExits...` | the 90% ratio applied to `lens.poolAbsorbable` | ratio is closed form, the base was the lens | **fixed**: the base is checked against a swap |
| `Crash`, fixed-edge test (new) | closed-form net sold; swap for the before figure | ok | **added**: depth to a fixed far edge falls by exactly what was sold, to the wei |
| `LensLayout.*` | the vaults' own storage through the harness | ok (independent of the lens decoding) | both orderings and both construction orders added |
| `VaultLifecycle`/`EdgeCases` previews | tokens moved by execution | ok | also run per ordering in `LensDepth.t.sol` with three positions (below, across, above spot) |
| `VaultGas` | no expected value (measurement) | n/a | none |
| `LensDifferential` (new, INV-9) | swap through a plain pool; band edges from `band_ticks_ref.json` | ok | **added**: random layouts and spots, both orderings, 18/6, 6/18 and 18/18, fee 0 and non-zero, non-zero protocol fee, lens before and after initialisation, exit netting; `3 x positions + 6` wei allowance (observed at most `positions + 1`) |
| `LensDepth` exact-floor tests (new) | integer arithmetic written in the test | ok | **added**: one-wei rounding is invisible to a comparison with a swap (the swap rounds up), so the floor is pinned exactly |

Two things the new tests found. First, the lens measures from the hook's anchor, which is a TWAP: with no time elapsed since initialisation the anchor is the spot, so the first version of the differential disagreed by 18%. That is correct behaviour; the test now lets 300 s elapse at the initial tick before moving the spot, and CONTRACTS says so. Second, the `Matrix` self-check showed the Crash fixture builds its pool inside each test, which would have hidden a mis-set variant; it now has its own variant test.

**Mutation evidence** (`tools/mutate.py`, `docs/MUTATION_LOG.md`): flipping the collateral direction in the lens, dropping the exit netting, rounding the committed depth up, rounding the live depth up, and rounding the netting up are each caught (38, 26, 18, 32 and 10 failing tests).

## M8 scenario and attacker suites (2026-11-27)
- `test/scenario/Manipulation.t.sol`: T3 (in-block spike, sustained push), T4, T5, T6. Attacker costs are logged with `-vv` and recorded in THREAT_MODEL.
- `test/scenario/ExitRace.t.sol`: T18; matured share of the supply versus liquidity that leaves before the lock engages (10%, 50%, 90%), and a late ticket being blocked.
- `test/unit/vaults/AttackerMocks.t.sol`: blocklisted payout token (T13, whole transaction reverts and funds stay), donations of tokens, claims and shares (T2), a griefing router (T19).
- INV-13 is the static selector enumeration (`§3.7`): it reads the ABI and fails on any selector not on the expected-caller list, so a new external function cannot ship unreviewed.
