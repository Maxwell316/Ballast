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
| `Observations` | Cumulative consistent with recorded ticks; interpolation exact; TWAP rounding toward −∞ |

### 3.3 Differential
- **Depth vs swaps:** build a pool with known liquidity; swap collateral in increasing steps until price reaches the band edge; the measured input net of fee MUST be ≥ `DepthMath` output and within the documented rounding bound.
- **Oracle vs model:** a naive Solidity model recomputes TWAP from the full tick history.
- **Stress vs table:** a table-driven reference of `(state, dev, time) → (state)`.

### 3.4 Invariant
Handler-based. Actors: three curators, five depositors, one sponsor, one trader, one time-warper.

Handler actions (each bounded and guarded to avoid trivially reverting calls):
`createVault`, `seed`, `deposit`, `requestRedeem`, `cancelRedeem`, `claimRedeem`, `rerange` (calm), `deployIdle`, `setCommitment`, `checkpoint`, `flagBreach`, `pokeStress`, `fundStandby`, `setStandbyRate`, `swapCollateralIn`, `swapQuoteIn` (various sizes), `warp`.

Ghost variables: total deposited and withdrawn per currency, total credited rewards, total funded, per-vault shares, number of lock violations (must stay zero), observed state transitions.

Invariants implemented: INV-1 … INV-14 (see CLAUDE.md §8.2). Use `fail_on_revert = false`, and assert in handlers that expected reverts are the expected errors.

### 3.5 Scenario
| Test | Narrative | Asserts |
|---|---|---|
| `Crash` | Price falls through the band; lock engages; liquidation-sized sell executes; exits blocked; market recovers; exits clear | Lock timing, no exit during lock, depth views over time, post-crash redeem succeeds |
| `Breach` | Anchor drift breaks coverage; grace; flag; accrual pauses; curator restores | Breach flow, record counters, accrual resumes |
| `Drought` | Sponsor stops funding | Accrual stops; `StandbyDepleted` once; depth views decay as exits mature |
| `Manipulation` | Attacker tries T3, T4, T5, T6 | Mitigations hold; attacker cost recorded |
| `Control` | Same liquidity in a plain pool vs Ballast under the same shock | Metrics feed SIMULATION |

### 3.6 Fork
Run key flows on the target chain's PoolManager at a pinned block. Skip with a clear message if `RPC_URL` is unset. Purpose: catch deployment-specific differences (hook flag bit order, token behaviour, PositionManager interaction).

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

## 8. Requirement-to-test starter map

| Area | Must-have tests |
|---|---|
| Pool binding | first pool binds; second reverts; dynamic fee reverts; native reverts; wrong currencies revert |
| Liquidity ownership | PositionManager add/remove revert; router add/remove revert; hook self-call works |
| Oracle | exact TWAP across sparse swaps; same-block double swap writes once; cold start warm flag |
| Stress | enter, recover, exit, relapse; lock expiry; no re-arm; cold pool stays CALM |
| Vaults | create/seed/deposit/redeem round trip; notice enforcement; lock blocks claim; cancel returns shares |
| Re-range | calm success; coverage failure reverts; stress reverts; idle remainder preserved |
| Standby | accrual; fund cap; breach stops; depletion event once; sniping unprofitable |
| Fees | crystallization separates `feesAccrued`; curator cut on fees and rewards only |
| Views | committed vs live depth; horizon netting; lock-aware netting; bounded gas |
| Guards | swap then vault op reverts; vault op then swap reverts; reentrancy attacker fails |
| Deployment | address flags equal permissions; script idempotent |

## 9. CI pipeline

`.github/workflows/ci.yml` runs: checkout with submodules, install Foundry, `forge fmt --check`, `forge build --sizes`, `forge test` (CI profile), `forge coverage` with threshold check, Slither, and compliance-matrix generation. Fork tests run on a schedule or manual dispatch if an RPC secret exists.
