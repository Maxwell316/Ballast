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

## ADR-004 — Use v4-periphery `BaseHook` (D-4)
**Status:** Accepted (pending VERIFY of the pinned API)
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

## Pending verification ADRs (to be written during M0/M2)

| Topic | Question |
|---|---|
| Hook self-call callback skip | Does the pinned PoolManager skip callbacks for self-calls? |
| Permission bit order on target chain | Is the target chain's bit order the final v4 order? |
| ERC-6909 base | Inherit v4-core's implementation or use another? |
| Compiler and EVM | Confirm 0.8.26 and `cancun`; transient storage support on chain |
| Dependency pins | Record commits for v4-core, v4-periphery, solady, forge-std, OZ hooks |
| `via_ir` | Needed or not, and why |
