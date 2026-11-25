# Ballast Threat Model

**Status:** Draft v0.1 · Companion to [SPEC](SPEC.md), [ARCHITECTURE](ARCHITECTURE.md). This document must be updated whenever a requirement, flow or parameter changes. It states residual risks plainly. It is not an audit.

---

## 1. Assets

| Asset | Where it lives | Why it matters |
|---|---|---|
| Depositor principal | Hook-owned PoolManager positions | Main custody risk |
| Idle balances, curator-owed fees | PoolManager claims held by the hook | Accrued yield and undeployed tokens |
| Standby fund | PoolManager claims held by the hook | Sponsor budget |
| Stress/lock state | Hook storage | Controls who can exit when |
| Depth views | Lens | Consumers size risk from them; wrong numbers can cause bad lending decisions |

## 2. Trust boundaries and assumptions

- The PoolManager is correct and not malicious.
- Collateral and quote tokens are standard ERC-20s (no fee-on-transfer, rebasing, blocklists, hooks or callbacks). Violations are out of scope and documented in SECURITY.
- The sponsor is trusted only to fund and set a bounded rate. It cannot touch custody.
- Curators are **not trusted** with funds, but depositors do trust them with management quality.
- Block timestamps on the target L2 are roughly honest; no logic relies on sub-minute precision.
- Consumers who read depth views understand that `committedDepth` is anchor-based and `liveDepth` is spot-based.

## 3. Attacker capabilities

Capital for price manipulation, the ability to deposit as any actor, to run contracts that call the hook in arbitrary orders, to front-run or back-run within a block, and to control a curator or sponsor address. Not assumed: breaking cryptography, compromising the PoolManager, or controlling the sequencer.

## 4. Threat analysis

### T1 — Liquidity added or removed outside the hook
**Attack:** use the PositionManager or a router to add liquidity (to dilute or game depth) or remove it (to escape the lock).
**Mitigation:** `beforeAdd/RemoveLiquidity` revert unconditionally; the hook's own calls skip callbacks. **VERIFY** the self-call behaviour in the pinned core.
**Evidence:** tests with the PositionManager and a minimal router for both directions; a smoke test in the deployment script.
**Residual:** none known beyond dependency correctness.

### T2 — Share inflation and donation attacks
**Attack:** inflate value per share so later entrants round to zero shares, or donate tokens to skew accounting.
**Mitigation:** shares are requested (not derived from deposited amounts); amounts are computed from liquidity and idle ledgers rounded up; no `balanceOf` accounting; `MINIMUM_SHARES` burned.
**Evidence:** donation fuzz test; INV-3, INV-4, INV-5.

### T3 — Pushing the price to trigger stress (trapping LPs)
**Attack:** move the short TWAP by `θ` in the liquidation direction to lock exits, perhaps to exit first or to harm a rival.
**Mitigation:** transitions use TWAPs, require sustained deviation, have hysteresis, the lock is bounded by `maxStressLock`, and cannot re-arm until CALM.
**Cost model (lower bound, to be measured in `Manipulation.t.sol`):** the attacker must (a) trade enough collateral to move spot by `θ`, a notional of at least the absorbable depth within `θ`; (b) hold the displacement for a large part of `shortWindow` while arbitrageurs push it back, repeatedly re-trading; (c) pay swap fees on every trade. Fees on the round trip alone are at least `2 · fee · notional`. If the attacker is also a vault shareholder, they recover only their pro rata share of the fees.
**Residual:** a well-capitalized attacker can still trigger a lock in a shallow pool. The bounded lock limits the harm, but depositors are trapped in a market they did not choose to be trapped in. Document clearly.

### T4 — Suppressing stress (keeping the lock off during a real crash)
**Attack:** counter-trade to keep the short TWAP near the anchor.
**Mitigation:** same TWAP properties; sustained suppression requires continuous buying against sellers.
**Residual:** a rich attacker can delay locks. The consequence is that exits are not frozen, which is the status quo without Ballast.

### T5 — Standby farming
**Attack:** collect rewards without delivering useful depth: thin liquidity at the far band edge, flash-adding depth around checkpoints, or timing a re-range.
**Mitigation:** `eligible = min(start, now, K_v)`; `maxAccrualInterval`; exit notice makes flash entry and exit impossible; re-range accrual uses `min(before, after)`; coverage must hold; breach stops accrual.
**Known limitation:** depth is counted equally anywhere in the band, so far-edge depth earns the same as near-edge depth. This matches the "price impact up to X" metric risk managers use, but is weaker than a path-weighted measure. Document it; consider weighting as future work.
**Known limitation:** the endpoint minimum does not bound intermediate dips under anchor drift; see MATH §7.

### T6 — Reward sniping
**Attack:** deposit just before rewards are credited and leave right after.
**Mitigation:** checkpoint (and credit to `idle`) precedes every share change; entrants pay in kind for idle that already includes the credit; the exit notice also deters in-and-out behaviour.
**Evidence:** fuzz test showing no profit from timing.

### T7 — Reentrancy and callbacks
**Attack:** reenter through token callbacks, receiver contracts, or the unlock callback.
**Mitigation:** transient reentrancy guard on every state-changing external function, checks-effects-interactions, ERC-20 only, `take` to a receiver after state updates.
**Evidence:** attacker mock contracts with callbacks.

### T8 — Gas denial of service
**Attack:** create many vaults or positions to make views or functions exceed gas limits.
**Mitigation:** `MAX_VAULTS`, `MAX_POSITIONS`, swap paths do not read vault data.
**Evidence:** worst-case gas tests; budgets in TESTING.

### T9 — Rounding drain
**Attack:** repeated small deposits/redeems to extract dust.
**Mitigation:** rounding always against the actor; internal ledgers; invariants INV-3 and INV-5; minimum meaningful sizes enforced by `ZeroShares`.

### T10 — Oracle cold start and sparse markets
**Attack/Issue:** a new pool has no history; sparse swaps make the TWAP slow to reflect changes.
**Mitigation:** `warm` flag; the state stays CALM while cold; exact accumulation between swaps.
**Residual:** a cold pool offers no lock protection. Document it.

### T11 — Sponsor griefing or exit
**Attack/Issue:** the sponsor stops funding or sets the rate to zero.
**Mitigation:** no custody powers; rate bounded; views decay honestly as exits mature.
**Residual:** guarantees rely on continued funding for new entrants; existing commitments obey notice and lock rules only.

### T12 — Curator mismanagement or malice
**Attack/Issue:** poor ranges, high fees (capped), self-dealing trades against their own vault, withholding re-ranges.
**Mitigation:** capped fee; no withdrawal power; visible record; depositors choose curators and can queue exits.
**Residual:** the design does not prevent losses from bad management. The record is information, not protection.

### T13 — Payout failure and stuck funds
**Attack/Issue:** a token transfer reverting on payout.
**Mitigation:** the transaction reverts; funds stay in the vault; the ticket owner can change the receiver at claim time.
**Residual:** a permanently failing token can block exits. Only standard ERC-20s are supported.

### T14 — Timestamp skew
**Mitigation:** all windows are coarse (minutes to hours); no logic depends on precise seconds.

### T15 — Wrong hook address bits or permissions drift
**Mitigation:** the deployment script asserts the mined address flags equal `getHookPermissions()`; a test checks the same. **VERIFY** bit-order on the target chain before mining the final address.

### T16 — Swap/vault-operation sandwiching
**Attack:** manipulate price immediately before or after a vault operation in the same transaction.
**Mitigation:** same-transaction guards (D-9); share maths independent of price; coverage uses the anchor, not spot.
**Residual:** cross-transaction manipulation within a block remains possible but has no effect on share accounting.

### T17 — Misleading consumers of the depth views
**Issue:** a lender reads `committedDepth` and assumes it is exit-proof forever.
**Mitigation:** `liveDepth` nets exits within a horizon; docs state that depth guarantees are "depth plus notice, bounded lock", not perpetual; the advisor takes an explicit horizon.

## 5. Design-level safety properties

| Property | Statement | Tests |
|---|---|---|
| No external liquidity | Only the hook owns positions | INV-1, T1 tests |
| No oracle-priced shares | No price enters mint or redeem | Unit + fuzz |
| Bounded trap | No lock outlasts `maxStressLock` and none re-arms before CALM | INV-6, INV-12 |
| Rounding safety | No actor gains from rounding | INV-3, INV-5 |
| No privileged custody | No role can move funds outside rules | INV-13 |

## 6. Out of scope

Dependency vulnerabilities in v4-core or periphery; token misbehaviour; chain reorgs or sequencer failure; legal or regulatory questions; economic sufficiency of the standby fee (see ECONOMICS).

## 7. Review checklist for auditors

- [ ] Confirm the self-call callback skip and PositionManager failure path.
- [ ] Walk every `unlockCallback` path; verify all deltas settle to zero.
- [ ] Confirm `modifyLiquidity` fee separation in every path.
- [ ] Confirm checkpoint-before-share-change in every function.
- [ ] Confirm rounding directions in `VaultMath`, `DepthMath`, `RewardMath`.
- [ ] Confirm bounds on all loops and that swap paths do not read vault state.
- [ ] Confirm no `balanceOf`-based accounting.
- [ ] Confirm hook address flags and permissions on the target chain.
