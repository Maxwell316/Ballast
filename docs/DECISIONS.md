# Architecture Decision Records

Append-only. Each entry: Context, Decision, Consequences, Status. Changing an accepted decision requires a new ADR that supersedes it and human approval.

---

## ADR-001 — No privileged roles (D-1)
**Status:** Accepted
**Context:** The hook custodies depositor liquidity; any pause or upgrade path becomes a trust and attack surface and undermines the guarantee that commitments cannot be broken.
**Decision:** No owner, pauser, admin, proxy or governance hook. The only privileged address is the immutable sponsor, limited to funding and a bounded rate.
**Consequences:** No emergency stop. Bugs require redeployment and migration. Strong audit focus and test bar.

## ADR-002 — One hook instance per pool (D-2)
**Status:** Accepted
**Decision:** Immutable configuration; the first `beforeInitialize` binds the pool; later initializations revert.
**Consequences:** Parameter changes mean a new deployment. Simpler state, simpler proofs.

## ADR-003 — Logic in small internal libraries (D-3)
**Status:** Accepted
**Decision:** Pure/`view` libraries for oracle, band, depth, stress, vault and reward maths. No external library linking. Read-only code that would push the hook near the size limit moves to `BallastLens`.
**Consequences:** Testable units; address mining stays simple.

## ADR-004 — Use a `BaseHook` (D-4)
**Status:** Superseded in part by ADR-030 (the `BaseHook` now comes from OpenZeppelin `uniswap-hooks`, not v4-periphery)
**Decision:** Inherit `BaseHook`; use OpenZeppelin `uniswap-hooks` only for audited utilities. Record pinned versions here once chosen.
**Consequences:** Aligns with the rubric's `BaseHook`/`getHookPermissions` language.

## ADR-005 — Minimal permissions (D-5)
**Status:** Accepted
**Decision:** Enable `beforeInitialize`, `afterInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`. No return-delta flags.
**Consequences:** Small attack surface; no `BeforeSwapDelta` use.

## ADR-006 — Bounded, non-re-arming stress lock (D-6)
**Status:** Accepted
**Context:** A lock that can be triggered repeatedly would trap depositors indefinitely.
**Decision:** The lock lasts at most `maxStressLock` per episode and cannot re-arm until the state returns to CALM.
**Consequences:** Guarantee is bounded; documented limitation under T3/T4.

## ADR-007 — Proportional, in-kind, oracle-free shares (D-7)
**Status:** Accepted
**Decision:** Deposits and redemptions are proportional in liquidity and idle balances. Shares are requested; amounts are computed. No NAV or price.
**Consequences:** Depositors must supply both tokens in the vault's current ratio (zapping is an external concern). Eliminates price-based share manipulation.

## ADR-008 — Standby fee in the quote currency (D-8)
**Status:** Accepted (confirm with Q-7)
**Decision:** Rewards are paid in quote and credited directly to vault idle balances.
**Consequences:** No per-user reward debt or transfer hooks; reward token fixed per deployment.

## ADR-009 — Same-transaction guards (D-9)
**Status:** Accepted (revisit if integrations break)
**Decision:** Vault operations and swaps cannot share a transaction in either order; transient flags enforce this.
**Consequences:** Zap-style single-transaction flows are unavailable. Defence in depth, not a core dependency.

## ADR-010 — Idle custody as PoolManager claims (D-10)
**Status:** Accepted (fallback allowed with ADR)
**Decision:** Idle balances, curator-owed amounts and the standby fund are PoolManager ERC-6909 claims. Vault shares are a separate ERC-6909 ledger in the hook.
**Consequences:** Idle movements stay inside flash accounting; requires careful naming and tests to avoid ledger confusion.

## ADR-011 — Own oracle library
**Status:** Accepted
**Decision:** Implement a v3-semantics observation buffer ourselves rather than copying GPL-licensed code.
**Consequences:** More tests required; licence clarity.

## ADR-012 — Reference-only supply-cap advisor
**Status:** Accepted
**Decision:** Ship a read-only advisor demonstrating the cap computation; no lending-protocol integration in v1.

---

## ADR-013 — Running oracle accumulator, rate-limited snapshots
**Status:** Accepted (human approved, Phase 0 review, item A)
**Context:** The original design rate-limited oracle writes and claimed the accumulator was exact between writes. A swap skipped by the rate limit would be attributed to the wrong interval, so the claim was false.
**Decision:** Keep a running accumulator `(lastSwapTs, lastTick, cumulative)` updated at every `beforeSwap` whose timestamp differs from `lastSwapTs`. Only the ring-buffer snapshots are rate-limited by `observationInterval`. The current cumulative and every snapshot value are exact. Interpolation between snapshots is exact only if no swap occurred between them; MATH §4 states the TWAP error bound `observationInterval × max tick swing / window`. R-ORC-1 to R-ORC-5 and the `Observations` signatures are rewritten.
**Consequences:** One extra hot-slot write per new-timestamp swap. Stress and anchor accuracy are bounded and testable against a full-history model.

## ADR-014 — Pool initialization restricted to an initializer; fee and tick spacing fixed in Config
**Status:** Accepted (item B)
**Context:** D-2 binds the hook to the first pool initialized. Anyone could front-run the intended initialization with a hostile price, fee or tick spacing.
**Decision:** `Config` gains immutable `initializer`, `fee` and `tickSpacing`. `beforeInitialize` requires `sender == initializer` (`PoolInitializerOnly`) and matching `key.fee` and `key.tickSpacing` (`InvalidPoolKey`). The deploy script deploys and initializes in one broadcast.
**Consequences:** Changing fee or spacing means a new deployment. The initializer needs no other power. Amends ADR-002.

## ADR-015 — `seed` is curator-only
**Status:** Accepted (item C)
**Context:** A third party seeding first would fix the cross-position liquidity ratios and the burned minimum of someone else's vault.
**Decision:** `seed` reverts unless called by the vault's curator. The `receiver` of the initial shares may be any address.
**Consequences:** Only the curator can bootstrap a vault.

## ADR-016 — Receiver chosen at claim time
**Status:** Accepted (item D)
**Decision:** `requestRedeem(vaultId, shares)` has no receiver parameter and tickets store none. `claimRedeem(ticketId, receiver)` is callable by the ticket owner or an address with `isOperator(owner, caller)`. Error `NotTicketOwner` becomes `NotTicketOwnerOrOperator`. T13 wording is updated.
**Consequences:** A failing receiver never traps funds; the claim can be retried with another receiver. ERC-6909 operator approval is the delegation mechanism.

## ADR-017 — `rerange` is CALM-only; stress additions use `deployIdle`
**Status:** Accepted (item E)
**Context:** CLAUDE.md §6.6 allowed an additive re-range in stress; SPEC §6.1 and R-VLT-10 made `rerange` CALM-only with `deployIdle` for additions.
**Decision:** SPEC wins. `rerange` reverts outside CALM. CLAUDE.md §6.6 is patched.
**Consequences:** No additive re-range mode to test. Curators add liquidity in stress only from idle.

## ADR-018 — Same-transaction guards cover five functions
**Status:** Accepted (item F; amends ADR-009)
**Decision:** `seed`, `deposit`, `claimRedeem`, `rerange` and `deployIdle` set `VAULT_OP` and revert if `SWAPPED` is set; `beforeSwap` reverts if `VAULT_OP` is set. R-TX-2 is amended.
**Consequences:** None beyond ADR-009's zap limitation.

## ADR-019 — Stress machine clarifications
**Status:** Accepted (item G)
**Decision:** (1) `stressStartedAt` is set only on CALM → STRESS; RECOVERING → STRESS does not reset it, otherwise a relapse could extend the lock indefinitely against D-6. (2) Warm means the anchor window is fully covered by retained snapshots, which implies the short window is covered. (3) Every state-changing function, including `claimRedeem`, evaluates stress first, so no poke is needed to release a lock; views use a pure preview of the transition. (4) Accepted approximation: continuity of the calm period is checked at evaluation points only.
**Consequences:** Documented in R-STR-1, R-STR-2, R-STR-6, R-STR-7, R-STR-9 and T3/T4.

## ADR-020 — Document precedence
**Status:** Accepted (item H)
**Decision:** SPEC and CONTRACTS win on behavioural detail; CLAUDE.md wins on scope and process. CLAUDE.md §0.1 is aligned with §18.

## ADR-021 — Sponsor funds are not withdrawable in v1
**Status:** Accepted (item I; Q-7 remains open)
**Decision:** There is no sponsor withdrawal. The sponsor stops spending by setting the rate to zero and funds in tranches. Listed as a limitation in SECURITY, ECONOMICS and THREAT_MODEL T11.
**Consequences:** Over-funding is unrecoverable. Preserves G-6 and keeps the sponsor's powers minimal.

## ADR-022 — Invariant wording: INV-3 and INV-13
**Status:** Accepted (item J)
**Decision:** INV-3 becomes an inequality: per currency, PoolManager claims held by the hook ≥ Σ vault idle + Σ curatorOwed + standby fund; principal conservation is checked through a ghost ledger of PoolManager-reported deltas with dust favouring the vault. INV-13 becomes a static access-control test enumerating all external selectors and expected callers, plus an audit item; it is not a runtime invariant.
**Consequences:** The test accounting is the only place PoolManager claim balances are read; contract code still never uses them for accounting.

## ADR-023 — Pool-wide views iterate vault positions
**Status:** Accepted (item K)
**Decision:** `liveDepth` and `poolAbsorbable` iterate vault positions, which is the whole pool by G-1, netting exits per vault. Loops stay bounded by `MAX_VAULTS × MAX_POSITIONS`. No tick scanning.

## ADR-024 — Minor specification fixes
**Status:** Accepted (item L)
**Decision:** (1) Threat IDs are T1 to T18 everywhere. (2) Cardinality hard minimum is `ceil(anchorWindow / observationInterval) + 1`; 1.1× is the recommended default. (3) README.md and SECURITY.md live at the repository root. (4) Absolute times are `uint40`, durations `uint32`; `StressMachine.Ctx` and `Observations` are updated. (5) If the ERC-6909 base lacks `totalSupply`, the hook tracks it in overridden mint and burn paths. (6) The hook never pokes a position whose recorded liquidity is zero (v4 behaviour to be verified in Phase 1).

## ADR-025 — Standby pays for depth still available
**Status:** Accepted
**Context:** Anchor-based committed depth is static in spot, so a crash that consumed a vault's liquidity would still earn standby.
**Decision:** At each sample, depth `d = min(anchor-based D_v, vault live depth from spot over bandBps)`; `eligible = min(d_start, d_now, K_v)`, in every state. Amends R-SBY-3 and MATH §7.
**Consequences:** Rewards fall as a crash consumes liquidity. Checkpoints need one live-depth computation per vault.

## ADR-026 — Exit race at crash onset accepted for v1 (T18)
**Status:** Accepted
**Context:** Short-TWAP stress detection lags spot, so matured tickets can exit in the first minutes of a crash.
**Decision:** Accept and document as T18. Add the `ExitRace` scenario test that quantifies matured-ticket liquidity that can exit before the lock engages. A spot-based fast trigger is a v2 option; it is manipulable and needs its own ADR.

## ADR-027 — `liveDepth` is the consumer figure
**Status:** Accepted
**Decision:** Lenders size caps from `liveDepth`. `committedDepth` is for coverage and reward accounting. Stated in CONTRACTS, README, SECURITY and R-VIEW-5.

## ADR-028 — Source of `BaseHook` and `HookMiner`
**Status:** Superseded by ADR-030
**Context:** v4-periphery master removed `BaseHook` and `HookMiner` (commit `5da22e60`, 2026-02-06). ADR-004/D-4 assumed they live there. See VERIFICATION F-1.
**Options:** (a) pin v4-periphery at `3779387e` (last commit with both files; builds under 0.8.26); (b) depend on `Uniswap/v4-hooks-public`; (c) vendor the two files; (d) OpenZeppelin `uniswap-hooks`.
**Recommendation:** (a), with v4-core pinned at `59d3ecf5`. The working tree currently uses this pin provisionally.
**Consequences if accepted:** supersedes the periphery-master assumption in ADR-004; `docs/DECISIONS.md` records pins; CLAUDE.md §7.13 and D-4 text are patched to name the pinned commit.

## ADR-029 — Settlement helper
**Status:** Superseded by ADR-030
**Context:** CLAUDE.md §7.2 requires a vetted settlement helper. The only in-tree one is v4-core `test/utils/CurrencySettler.sol` (test code). See VERIFICATION F-8.
**Options:** vendor a minimal reviewed `CurrencySettler` into `src/libraries` with attribution, or add OpenZeppelin `uniswap-hooks`.

## ADR-030 — Adopt OpenZeppelin `uniswap-hooks` for `BaseHook` and `CurrencySettler`
**Status:** Accepted (supersedes ADR-028 and ADR-029; amends D-4)
**Context:** v4-periphery master no longer ships `BaseHook` or `HookMiner`. The human asked for an evaluation of OpenZeppelin `uniswap-hooks` as a single dependency, with a decision rule: adopt if it compiles with our pins, has a maintained audited `BaseHook`, and its settler covers claims; otherwise pin periphery at `3779387e` and vendor a settler. Evidence: `docs/VERIFICATION.md` F-1.
**Decision:** Adopt `uniswap-hooks` v1.2.1 (`acbd604c`) for `BaseHook` and `CurrencySettler`. D-4 now reads "OpenZeppelin `BaseHook`". v4-periphery stays as a test-only dependency (PositionManager, Permit2). We write our own minimal `HookMiner` in `script/utils` with unit tests.
**Rule check:** compiles with v4-core `59d3ecf5`, solc 0.8.26, cancun: yes. Maintained: yes (v1.2.1 stable, 1.3.0 on main, active). Audited `BaseHook`: `BaseHook` and `CurrencySettler` were in audited scopes (v1.0.0 and v1.1.0 RC 2 per OpenZeppelin's pages) but v1.2.1 itself is not audited and the README disclaims audit, so the rule is met **with a caveat**. Settler covers claims: yes (`burn` and `claims` flags), proven on the real PoolManager.
**Consequences:** One OpenZeppelin dependency; `@openzeppelin/contracts` v5.5.0 comes only as its nested submodule (we use no other OZ code). `_validateHookAddress` is non-virtual, so tests use `deployCodeTo`. The `_before*` surface equals the old periphery `BaseHook`, so reverting to the fallback is cheap if the caveat becomes unacceptable. We must write and test `HookMiner` ourselves. Re-review the v1.1.0..v1.2.1 diff of the two files at audit time.

## ADR-031 — Gross-up uses the effective swap fee
**Status:** Accepted
**Context:** The PoolManager owner can set a protocol fee (at most 1000 pips per direction in the pinned core), which combines with the LP fee as `p + l − floor(p·l/1e6)`.
**Decision:** MATH §3 defines the optional gross-up with the effective fee read from `slot0` for the liquidation direction. Depth reported to consumers stays net of fees. Owner control of the protocol fee is documented in SECURITY and THREAT_MODEL as a dependency-level trust assumption, not a Ballast privilege.

## ADR-032 — Resolution of open questions Q-2, Q-3, Q-4, Q-8, Q-9
**Status:** Accepted
**Decision:** Q-2 licence MIT. Q-3 chain Unichain Sepolia, ID 1301. Q-4 demo assets are mocks (decimals still to choose). Q-8 curators are permissionless. Q-9 deposits are blocked in both STRESS and RECOVERING (as SPEC §6.1 already states). Q-1, Q-5, Q-6, Q-7 remain open.

## ADR-033 — StressMachine takes `warm`; `rearmBlocked` becomes `lockExpiryRecorded`
**Status:** Accepted (human approved, M0/M1 plan)
**Decision:** `StressMachine.next(state, dev, warm, ctx)` takes `warm` so R-STR-6 lives in the pure function. `rearmBlocked` is replaced by `lockExpiryRecorded`. With ADR-019 (`stressStartedAt` set only on CALM → STRESS) an expired lock cannot become active again without an intervening CALM, so the old flag was redundant; the new flag exists only so `LockExpired` is emitted once. It is set when expiry is first evaluated in a non-CALM state and cleared on CALM → STRESS. A non-CALM state with `warm == false` returns CALM (unreachable; fails safe).

## ADR-034 — Warm is monotonic (R-ORC-7, INV-15)
**Status:** Accepted
**Decision:** Warm is derived (oldest snapshot ≤ now − window), not latched. It is monotonic because snapshots are ≥ `observationInterval` apart and cardinality ≥ `ceil(anchorWindow/observationInterval) + 1` (proof in MATH §4). A fuzz test and invariant INV-15 check it. When not warm, `twapTick` divides by the actual elapsed time since the oldest snapshot (R-ORC-6).

## ADR-035 — `bpsToTicksDown` epsilon rule
**Status:** Accepted
**Decision:** `bpsToTicksDown = floor((Δ_raw − 1e9 WAD-units) / 1e18)` where `Δ_raw` comes from `lnWad`. The postcondition against a committed 60-digit reference table is `floor(Δ_ref) − 1 ≤ result ≤ floor(Δ_ref)` for all `bps ∈ [1, 2500]`, and `Δ_wad ≤ Δ_ref`. See MATH §2.

## ADR-036 — Oracle gas design
**Status:** Accepted
**Decision:** `beforeSwap` performs only the O(1) accumulator update and at most one snapshot write per `observationInterval`. The ring buffer grows lazily by push (no up-front storage cost). Binary search runs only on the stress-evaluation path (at most once per interval) and in views. Measured gas per path is recorded in `.gas-snapshot` and TESTING.

## ADR-037 — Configuration additions
**Status:** Accepted
**Decision:** SPEC §14 is now R-CFG-1 and additionally requires `sponsor != address(0)` (a zero sponsor would permanently disable standby funding). The `stressExit < stressEnter` check after bps→tick rounding needs no extra code: consecutive bps differ by at least `1/ln(1.0001) ≈ 1.0001` ticks, so exit < enter in bps implies `round(Δ(exit)) < round(Δ(enter))`; `BandMath.t.sol` verifies it for every enter in [51, 2500].

## ADR-038 — Oracle evaluation gas: measurements, and search cursors
**Status:** Accepted (human decision rule, M2 approval: accept if the evaluation path is at or under about 100k; otherwise add monotone cursors with a binary-search fallback, differential-tested)
**Context:** M1 estimated about 85k gas for two binary searches alone. M2 measured the real `beforeSwap` through `PoolManager.swap` (`test/gas/BeforeSwapGas.t.sol`, gas inside `_beforeSwap`, storage cold via `vm.cool`, forge 1.8.4, cardinality 1,585, interval 60 s).
**Measurements (before cursors):** no update (same timestamp) 4.7k; update only 8.7k; update + snapshot + evaluation, cold oracle 52k; warm, ring filling (push) **113k**; warm, wrapped ring **97k**.
**Decision:** the warm, ring-filling path was over 100k, so monotone cursors were implemented (R-ORC-8): one cursor per window (anchor and short), validated by slot content and timestamp, walk of at most 4 snapshots, fallback to binary search. `test/fuzz/ObservationsCursor.t.sol` differential-tests the hinted lookup against the binary search over fuzzed histories with wraparound, long gaps, garbage and stale cursors.
**Measurements (after cursors):** warm ring-filling 84.6k, wrapped steady state 68.4k (TESTING §7). Budget amended: steady state < 80k (met), the first ring fill (the first `cardinality` snapshots, about 26 h at defaults) ≤ 90k; common paths < 30k (met).
**Consequences:** two extra cursors (112 bits, one slot) written at each evaluation (about 5k). A stale or zeroed cursor costs one full binary search, never a wrong answer.

## ADR-039 — `beforeSwap` totality (R-STR-10) and the oracle domain
**Status:** Accepted (human decision, M2 approval)
**Decision:** swaps cannot be blocked by Ballast. `beforeSwap` reverts only for the D-9 guard. The oracle, evaluation and transition are total inside a stated domain (R-ORC-9): `block.timestamp < 2^40` and under about 1,286 years of history, so the `int56` accumulator cannot overflow (MATH §4). We chose to state the domain instead of wrapping arithmetic or catching reverts: a `try/catch` around the update would hide real bugs and leave oracle state inconsistent, and wrapping would silently corrupt TWAPs. Evidence: the `BeforeSwapTotality` invariant (arbitrary ticks including MIN/MAX written straight into the PoolManager's slot0, zero and huge time steps, all stress states, three entry points) and a fuzz test over starting pools, the `LiquidationDuringStress` scenario, and the legal-transition check (INV-12).
**Consequences:** the proof obligation is the domain statement. A chain with a clock beyond year 3000 is out of scope.

## ADR-040 — Deployment script deploys the hook with an explicit call to the CREATE2 deployer
**Status:** Accepted
**Context:** the first M2 dry run failed the script's own flag check: with `new BallastHook{salt: s}(...)` the dry run created the hook as a CREATE2 from the *sender*, not through the deterministic deployer, so the address differed from the one mined for `CREATE2_FACTORY` (observed: predicted `0x5b78…ba80`, created `0x38aE…Ce66`, which equals CREATE2 from the sender with the same salt and init code). Whether Foundry reroutes `new{salt}` differs between dry run and broadcast.
**Decision:** the script calls the deployer proxy explicitly (`create2Deployer.call(salt ++ initcode)`), then asserts the code exists at the mined address and that the address flags equal `getHookPermissions()`. `test/fork/DeployBallastScript.t.sol` runs the real script on a fork of chain 1301.
**Consequences:** the address no longer depends on Foundry's routing; the script needs the deployer proxy to exist on the chain (asserted).

## ADR-041 — `HookPermissions` is the single definition of the permission set
**Status:** Accepted
**Decision:** `HookPermissions.permissions()` and `flags()` are used by `BallastHook.getHookPermissions()` and by `DeployBallast`, so the contract and the mining flags cannot drift. The test suite derives the mask independently (`HookCallbacks.t.sol::_mask`, and per-flag checks in `HookPermissions.t.sol`).

## ADR-042 — Evaluation triggers: snapshot-gated in `beforeSwap`, `pokeStress` advances the oracle
**Status:** Accepted
**Decision:** `beforeSwap` evaluates stress only when the update wrote a snapshot, which rate-limits evaluation to once per `observationInterval` without a second timer. `pokeStress` always evaluates and also calls `Observations.update` with the current tick: this is exact (price changes only at swaps), so the accumulator and snapshots progress through swap droughts and anyone can keep the oracle warm. While the anchor window is not covered, the write path skips the TWAP lookups; views always compute them.
**Consequences:** SPEC R-STR-7 clarified. No behavioural difference for the machine.

## ADR-043 — Second reference for `StressMachine`
**Status:** Accepted (human decision, M2 approval)
**Decision:** `tools/gen_stress_vectors.py` (dated 2026-11-26, seed 20261126) generates 300 event-driven timelines (10,410 evaluation points) from the SPEC text only, with a history-recomputing structure unlike the carried-timer Solidity; `test/vectors/stress_machine.json` is committed and replayed by `test/fuzz/StressMachineVectors.t.sol`. Result: 0 disagreements; the vectors contain 267 RECOVERING→CALM transitions, 1,118 relapses and 491 `LockExpired` emissions.
**Independence caveat:** both references were written by the same author, so the structure is independent but the reading of the SPEC is not. Two readings the SPEC states only implicitly are recorded here for the human to confirm: (1) a dev between the thresholds interrupts an in-progress calm period (R-STR-3 "held continuously"); (2) in STRESS, a dev between the thresholds keeps STRESS. One wording difference was found between SPEC and code (R-STR-5 said the expiry flag is cleared on entering STRESS; the code clears it on every transition into CALM); they are observationally equivalent, and SPEC was reworded.

## ADR-044 — Test-only subclass and Foundry transient-storage behaviour
**Status:** Accepted
**Decision:** the D-9 guard helpers and the reentrancy lock are `internal`, with no production caller until M3. A test-only subclass `BallastHookHarness` (in `test/utils`, never in `src/`, so nothing is compiled out of the release bytecode) exposes them, provides the hook's own liquidity entry points used as a stand-in for vault operations, and measures gas. Forge 1.8.4 clears transient storage between top-level calls of a test (verified: probe test, identical results with `--isolate`), so "guard resets between transactions" is testable with separate calls; `test_ProbeSeesSeparateTransactions` fails loudly if a future Foundry stops doing that.

## Carry-forward note for M3 (re-range dust)
The fork test showed that removing liquidity rounds amounts down and adding rounds up, so recovered tokens do not exactly refund the same liquidity. `rerange` must therefore not assume it can re-add the removed liquidity from the recovered tokens alone. The M3 plan must propose: how a shortfall of a few wei per position and currency is funded from `idle`; what happens when idle is insufficient (revert with a clear error versus reducing liquidity); who bears the cumulative dust loss (shareholders, pro rata, since no actor is charged); and a test that the loss is bounded per re-range.

## Pinned dependencies

| Dependency | Commit / tag | Role |
|---|---|---|
| v4-core | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` (v4.0.0 + 12) | Core |
| OpenZeppelin `uniswap-hooks` | `acbd604c409a827f7f98c9517236da860c4fca1a` (v1.2.1) | `BaseHook`, `CurrencySettler` |
| ↳ `openzeppelin-contracts` (nested) | `fcbae5394ae8ad52d8e580a3477db99814b9d565` (v5.5.0) | `SafeERC20` |
| v4-periphery | `c6e4754dab11bd38c6f08ac51c3c868569e93d64` | Tests only |
| solady | `acd959aa4bd04720d640bf4e6a5c71037510cc4b` (v0.1.26) | Maths, transient guard |
| forge-std | `f3dae6e6ee381f25eb6a246f7da9b85c91a68219` (v1.17.0) | Tests, scripts |
| Foundry | forge 1.8.4 (`50af4efe`) | Tooling |
| solc / EVM | 0.8.26 / cancun | Compiler |

## Verification status (Phase 1; evidence in [VERIFICATION.md](VERIFICATION.md))

| Topic | Result |
|---|---|
| Hook self-call callback skip | Confirmed in source (F-2); behavioural tests on a local and a forked PoolManager (M2: `HookCallbacks.t.sol`, `HookOnlyLiquidityFork.t.sol`) |
| Permission bit order on target chain | Bytecode identical to Ethereum mainnet PoolManager; init bits proven by fork probe; remaining bits due M2/M9 (F-3) |
| ERC-6909 base | v4-core `ERC6909` with own `totalSupply` via `_mint`/`_burn` overrides (F-4) |
| Compiler and EVM | 0.8.26 and `cancun` build; `TLOAD` works on chain 1301 (F-5) |
| Dependency pins | Recorded in the "Pinned dependencies" table below |
| `via_ir` | Not needed so far |
| Settlement helper | OpenZeppelin `CurrencySettler` (ADR-030) |
| Five hook flags on chain 1301 | Exercised by `test/fork/HooksOnChain.t.sol` (F-3) |


## ADR-045 — Split custody: `BallastHook` and `BallastVaults`
**Context:** The M3–M7 vault logic written into `BallastHook` produced a runtime of 40.6 KB (`via_ir`) / 46.1 KB (legacy, `optimizer_runs = 1`) against the 24,576-byte limit (M2 hook alone: 13.5 KB). Stubbing each function to a revert showed no single hog, so trimming cannot close the gap.
**Decision (maintainer-approved):**
- `BallastHook` keeps the callbacks, the oracle, the stress machine and the liquidity gate. `BallastVaults` owns positions, vault shares (ERC-6909), PoolManager claims and all vault operations. The hook creates the vaults contract in its own constructor (`new BallastVaults(...)`), so the two immutable addresses are not circular and neither contract has an owner, admin, proxy or `delegatecall`.
- D-2 stands (one hook per pool) and extends to one vaults contract per hook. **D-3 is amended:** one hook plus one custody contract; pure maths stays in internal libraries.
- **G-1 is reformulated:** only the `BallastVaults` contract, created by the hook in its constructor, can add or remove liquidity in the pool; the hook callbacks enforce this with an explicit sender check (`sender == address(vaults)`). **INV-1:** every position is owned by the vaults contract. The old reliance on the PoolManager's self-call skip is removed (R-LIQ-1, R-LIQ-4, T1). Because the vaults contract is not the hook, the PoolManager *does* call the hook's `beforeAdd/RemoveLiquidity` for it, and the check lets it through.
- **Acyclic calls.** The hook never calls the vaults after its constructor. The vaults call the hook through two functions only: `enterVaultOp()` (restricted to the vaults address; reverts if `SWAPPED`, sets `VAULT_OP`; the transient flags stay in the hook) and `evaluateStress()` (permissionless; the logic of `pokeStress`, returning the evaluation). The reentrancy guard lives in the vaults; the swap-path guard stays in the hook.
- The hook does not implement `IUnlockCallback` and contains no call to `modifyLiquidity` or `unlock` (T19). A test inspects the compiled runtime bytecode for the `modifyLiquidity` selector and for `unlockCallback`.
- The hook's initcode embeds the vaults' creation code. EIP-3860 allows 49,152 bytes; a test asserts a margin, and `HookMiner` mines with the full creation code. The M2 testnet deployment is superseded by the M9 deployment.
- Size protocol: both runtime sizes stay below 23,800 bytes. If the vaults exceed it, the standby fund and accrual move to a third contract `BallastStandby` under the rules in ADR-046 (written with measurements first). No further splits without maintainer approval. No `delegatecall`, proxies or dispatcher mega-functions.
**Consequences:** each liquidity operation now also triggers a hook callback (gas up; re-measured in TESTING). `previewDeposit`/`previewRedeem` move to the lens (estimates). Mining and the manifest cover two addresses.

## ADR-046 — Compiler settings, `BallastStandby`, and the size/initcode measurements
**Context:** After the ADR-045 split the sizes were measured with `forge build --sizes` (solc 0.8.26, cancun, `optimizer = true`, `optimizer_runs = 200`; `via_ir` needed for stack depth in the vault operations).

| Build | Hook runtime | Hook initcode | Vaults runtime | Vaults initcode | Standby runtime |
|---|---|---|---|---|---|
| Split custody, legacy pipeline | 14,556 | 56,277 | 34,668 | 37,068 | n/a |
| Split custody, `via_ir` | 14,027 | 50,052 | 29,912 | 32,060 | n/a |
| + `BallastStandby` (fund, rate, accrual), `via_ir` | 14,027 | 53,457 | 28,959 | 35,465 | 3,105 |

Limits: runtime 23,800 (24,576 hard); hook initcode 49,152 (EIP-3860), margin target 3,000.
**Findings:** (1) `via_ir` is needed (stack-too-deep in the vault operations) and is 13% smaller than legacy; `optimizer_runs = 1` gained nothing. (2) The standby split lowered the vaults runtime by only 953 bytes while *raising* the hook's initcode by 3,405, because the hook's initcode embeds the vaults' creation code, which embeds the standby's. (3) The vaults runtime is still 5.2 KB over, and the hook initcode is 4.3 KB over the EIP-3860 limit.
**Status:** `BallastStandby` follows the maintainer's rules (vaults own all liquidity; the standby holds only the sponsor fund as claims, pays rewards by claim transfer to the vaults, calls nothing but the PoolManager; call graph acyclic). The remaining gap needs a maintainer decision (see PROGRESS.md); no further split has been made.

## ADR-047 — Exit netting uses the earliest possible release, not `lockedUntil`
**Context:** `max(maturity, lockedUntil)` assumes the lock lasts to its hard cap, but the lock can end earlier when the market calms, so it overstates guaranteed depth.
**Decision (maintainer-approved):** `earliestRelease = min(lockExpiry, earliestCalm)`, `lockExpiry = stressStartedAt + maxStressLock`; `earliestCalm` is `now` in CALM (no lock) or when the lock has expired, `now + calmDuration` in STRESS, and `max(now, belowExitSince + calmDuration)` in RECOVERING (`belowExitSince` is the calm timer's start; 0 means the timer is not running, so `now + calmDuration`). The effective exit time of a ticket is `max(maturity, earliestRelease)`. `lockedUntil` stays in `StressInfo` and `lockState()` as informational: an **upper bound only**. `StressInfo.earliestRelease` is added. Exact formula in MATH §5a; SPEC R-VIEW-2/R-VIEW-3; vectors added to the stress reference tests.

## ADR-048 — Bucketed ticket aggregation for exit netting; previews move to the lens
**Context:** `liveDepth` must net tickets maturing within a horizon, but loops over tickets are unbounded and a capped open-ticket list can be griefed.
**Decision:** Tickets keep exact maturity for claims. For netting, each vault keeps `EXIT_BUCKETS = 16` maturity buckets of width `ceil(exitNotice / 16)` seconds plus a matured pool. A bucket counts as exiting when its start (maturity rounded down) is within the horizon, so the figure is never below the exact one (conservative). A slot reused by a later epoch folds into the matured pool. Views are bounded by `MAX_VAULTS × 16`. `previewDeposit`/`previewRedeem` move to `BallastLens`; they are estimates.

## ADR-049 — Re-range dust rule
**Decision:** Re-range removes all liquidity and re-adds the curator's `liquidities` in one unlock; the net per currency settles against vault idle. If idle cannot cover a shortfall, the largest new position is shrunk by the minimal liquidity whose removal covers it (once per currency); otherwise `InsufficientIdle`. Coverage is then checked (`CoverageBelowCommitment`). Test bound: idle decrease per re-range ≤ 2 × (n_old + n_new) per currency for a same-range re-range.

## ADR-050 — Vaults are deployed separately and bound to the hook in both directions; `BallastShares`, `BallastDepth`, `extsload`
**Status:** accepted (maintainer decision, 2026-11-26). Supersedes the "created by the hook in its constructor" part of ADR-045; the rest of ADR-045 stands.
**Context:** After ADR-046 the hook's initcode (53,457 bytes) exceeded EIP-3860's 49,152 because it embedded the vaults' creation code, and the vaults' runtime (28,959) exceeded the target.
**Decision:**
1. *Deployment order.* The deployer predicts the vaults address from its nonce (CREATE), the hook salt is mined over the full creation code plus constructor arguments (which contain the predicted vaults address), the vaults are deployed with the mined hook address as an immutable, then the hook is deployed with CREATE2. The hook's initcode no longer embeds the vaults (18,117 bytes).
2. *Bindings.* The hook's constructor requires `vaults.code.length > 0`, `vaults.hook() == address(this)` and `vaults.configHash() == keccak256(abi.encode(config))`. These constructor-time staticcalls are the hook's only calls into the vaults and are an explicit, documented exception to the acyclic rule (after construction the hook calls nothing on the vaults). The vaults' constructor cannot check the hook (it has no code yet); instead every vault entrypoint needs an existing vault, vaults can only be created after the pool is bound, and binding requires the hook to have code. `DeployBallast` asserts the nonce, both predicted addresses and both directions; `script/VerifyBinding.s.sol` asserts the full graph (hook.vaults, vaults.hook, shares.vaults, standby.vaults, config hash, flags, pool id, lens). A deployment is valid only if it passes.
3. *Threat T20 (mis-binding at deployment)* is added to the threat model with these mitigations. G-1 is reworded: "Only the `BallastVaults` contract bound immutably at deployment can add or remove liquidity; the hook's callbacks enforce this with an explicit sender check."
4. *`BallastShares`* (ERC-6909 on v4-core's `ERC6909` plus `totalSupply`) is created by the vaults' constructor with `vaults = msg.sender`; only the vaults can mint, burn or `move` (escrow). Escrow is the vaults' own balance there. INV-4 reads: `totalSupply(v) = Σ balances of v (holders, the vaults' escrow balance, address(0))`.
5. *`BallastDepth`* is a stateless external wrapper over `DepthMath`/`BandMath` (and the re-range dust formula), created by the vaults' constructor. The lens, the vaults and the standby accounting use the same library code; `BallastDepthDifferential` compares the contract to the library on fuzzed inputs. It holds no funds and no state, so it cannot affect custody; it was not hosted in `BallastStandby` because the standby holds the sponsor fund.
6. *`extsload`.* The vaults expose `extsload(slot, n)` as their only added read primitive. The lens decodes vault state with it; the vault views (`vault`, `positionsOf`, `ticket`, `record`, `exitingShares`, `vaultCount`) moved to the lens. `VaultsLayout` pins the slots; `LensLayout.t.sol` compares every decoded field with the vaults' state through `BallastVaultsHarness`, so a layout change breaks the build. `docs/storage-layout.md` is generated from `forge inspect` (M11).
**Measurements** (`via_ir`, `optimizer_runs = 200`): hook 14,027 / 18,117 initcode; vaults 24,258 / 36,184; shares 2,022; depth 2,889; standby 3,105; each initcode is more than 12 KB under 46,152 (limit minus the 3,000 margin). Enforced by `test/unit/Sizes.t.sol`.

## ADR-051 — Size ceiling for the vaults, and what was cut to reach it
**Status:** accepted. The target for every runtime is 23,800 bytes. After the approved reductions the vaults are at 24,258 (margin 318 to EIP-170), inside the permitted band (at most 24,300, margin of at least 250, asserted by `Sizes.t.sol`).
**Steps, each measured:** 27,334 (shares and depth moved out, views to the lens) → 25,850 (re-range dust formula into `BallastDepth`, one range validator) → 25,350 (modifier body behind private functions, one curator-check helper) → 25,082 (`seed` and `deposit` share one operation, ADR-053) → 24,787 (one settlement routine) → 24,696 (`flagBreach` as an operation, then removed, below) → 24,338 → 24,258 (shared seeded check; `setCommitment` with a zero notice stays pending until the next checkpoint instead of a special branch). `optimizer_runs = 1` fails with stack-too-deep.
**Cut taken (fallback a):** the public `flagBreach` was removed (ADR-052). Cuts b to d were not needed. If later work pushes the vaults above 24,300, the remaining order applies: (b) `setCommitment` simplification, (c) `deployIdle`, (d) `cancelRedeem`; each needs its own ADR.
**Removed extra:** the event `FeesCrystallized`, which no document specified.

## ADR-052 — Breach is detected at the first checkpoint after the grace period; no public `flagBreach`
**Context:** fallback (a) of the size rules. **Decision:** `_updateCoverage` runs in every checkpoint, deposit, redeem, re-range and `deployIdle`. In CALM it clears a breach when coverage is restored, starts the grace clock (`CoverageLost`) on first seeing lost coverage, and flags the breach (`BreachFlagged`, `breachCount++`) at the first call after `rerangeGrace`; accrual stops from then on. Anyone can trigger it with the permissionless `checkpoint(vaultId)`. Outside CALM nothing is enforced (R-COV-4) and the clock resets. SPEC R-COV-1/2, CONTRACTS and TESTING are patched. **Consequence:** the interval ending at the flagging checkpoint accrues at the pre-flag state (as every interval does); the vault earns nothing for intervals after it.

## ADR-053 — Seed and deposit share one operation; one settlement routine
**Decision:** `_opAdd` implements both: a seed supplies per-position liquidity and mints `INITIAL_SHARES - MINIMUM_SHARES` plus the burned minimum; a deposit scales positions and idle by `ceil(shares / supply)`. Settlement goes through one routine, `_cash(mode, ...)`, which skips zero amounts. Behaviour is unchanged; the change is for code size. The seeded vault's first checkpoint state (`lastCheckpoint`, `lastDepthSample`) is set exactly as before.

## ADR-054 — Tests read `vm.getBlockTimestamp()`, not `block.timestamp`
**Context:** with `via_ir`, `block.timestamp` read after `vm.warp` inside one test function can be folded to a constant, so `vm.warp(block.timestamp + 1)` in a loop did not advance time and four M2 tests failed with `TimeRegression`. **Decision:** every test reads time with `vm.getBlockTimestamp()`. Source contracts are unaffected (a real transaction sees one timestamp).

