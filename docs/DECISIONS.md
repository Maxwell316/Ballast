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
**Decision:** SPEC §14 is now R-CFG-1 and additionally requires `sponsor != address(0)` (a zero sponsor would permanently disable standby funding). The `stressExit < stressEnter` check also applies after bps→tick rounding (added with `BandMath`).

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
| Hook self-call callback skip | Confirmed in source (F-2); behavioural test due in M2 |
| Permission bit order on target chain | Bytecode identical to Ethereum mainnet PoolManager; init bits proven by fork probe; remaining bits due M2/M9 (F-3) |
| ERC-6909 base | v4-core `ERC6909` with own `totalSupply` via `_mint`/`_burn` overrides (F-4) |
| Compiler and EVM | 0.8.26 and `cancun` build; `TLOAD` works on chain 1301 (F-5) |
| Dependency pins | Recorded in the "Pinned dependencies" table below |
| `via_ir` | Not needed so far |
| Settlement helper | OpenZeppelin `CurrencySettler` (ADR-030) |
| Five hook flags on chain 1301 | Exercised by `test/fork/HooksOnChain.t.sol` (F-3) |
