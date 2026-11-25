# Ballast Specification

**Status:** Draft v0.1 · **Audience:** implementers, reviewers, auditors · **Companion docs:** [MATH](MATH.md), [CONTRACTS](CONTRACTS.md), [ARCHITECTURE](ARCHITECTURE.md), [THREAT_MODEL](THREAT_MODEL.md)

This is the normative description of Ballast's behaviour. The keywords MUST, MUST NOT, SHOULD and MAY follow RFC 2119. Requirement identifiers (`R-AREA-n`) are referenced from tests and NatSpec. Where this document or `CONTRACTS.md` and `CLAUDE.md` disagree on behavioural detail, this document and `CONTRACTS.md` win; on scope and process, `CLAUDE.md` wins (ADR-020). Items marked **VERIFY** depend on dependency facts that must be checked against the pinned `lib/` sources.

---

## 1. Purpose and scope

Ballast is a Uniswap v4 hook for a single pool of a collateral asset against a quote asset. It makes the pool's entire liquidity **committed**: curators run vaults that hold all liquidity, exits are queued, and exits freeze while the market is under stress. It publishes depth figures that lending risk consumers can read. A sponsor pays a standby fee for verified committed depth.

Out of scope: native ETH, fee-on-transfer or rebasing tokens, upgradeability, admin roles, multi-pool vaults, auctions, cross-chain operation, protection against price loss.

## 2. Definitions

| Term | Meaning |
|---|---|
| Collateral `C` / Quote `Q` | The asset liquidators sell into the pool / the asset they receive |
| Liquidation direction | Price direction caused by selling `C` into the pool: ticks fall if `C` is currency0, rise if `C` is currency1 |
| Anchor `A` | TWAP tick over `anchorWindow` |
| Short price `S` | TWAP tick over `shortWindow` |
| Band | Tick interval from `A` to `A ∓ bandTicks` in the liquidation direction |
| Absorbable collateral | Collateral that must be sold into the pool to move the price across an interval (see MATH §3) |
| Committed depth `D_v` | Sum over a vault's positions of absorbable collateral over `position ∩ band` |
| Live depth | Absorbable collateral from current spot down `impactBps`, net of exits maturing inside a horizon |
| Commitment `K_v` | Collateral amount a vault promises to keep absorbable inside the band |
| Coverage | `D_v ≥ K_v` |
| Idle | Vault balances not deployed in positions, held as PoolManager claims |
| Lock active | State ≠ CALM and `now < stressStartedAt + maxStressLock` |

## 3. Pool binding

- **R-POOL-1** The hook MUST bind to exactly one `PoolId` during the first `beforeInitialize` and MUST revert any later initialization of a different pool (`PoolAlreadyBound`).
- **R-POOL-6** `beforeInitialize` MUST revert with `PoolInitializerOnly(sender)` unless its `sender` argument equals the immutable `config.initializer`, and MUST revert with `InvalidPoolKey` unless `key.fee == config.fee` and `key.tickSpacing == config.tickSpacing`. This prevents a third party from binding the one-pool hook to an attacker-chosen pool. The deployment script deploys the hook and initializes the pool in one broadcast (ADR-014).
- **R-POOL-2** `beforeInitialize` MUST revert if `key.hooks != address(this)`, if the fee is dynamic (`DynamicFeeUnsupported`), or if either currency is native (`NativeCurrencyUnsupported`).
- **R-POOL-3** The pool's two currencies MUST be exactly `{config.collateral, config.quote}` (`InvalidPoolKey`). The hook MUST record whether the collateral is currency0.
- **R-POOL-4** `afterInitialize` MUST seed observation 0 with the pool's initial tick and the current timestamp.

## 4. Liquidity ownership

- **R-LIQ-1** `beforeAddLiquidity` MUST revert with `ExternalLiquidityForbidden` for every caller that reaches it.
- **R-LIQ-2** `beforeRemoveLiquidity` MUST revert with `ExternalLiquidityForbidden` for every caller that reaches it.
- **R-LIQ-3** All positions MUST be owned by the hook. Position salt MUST be `bytes32(vaultId << 8 | slot)`, unique per `(vaultId, slot)`.
- **R-LIQ-4** The hook's own liquidity operations rely on the PoolManager skipping hook callbacks for self-calls. A deployment smoke test MUST demonstrate that the hook can modify liquidity while an external router and the PositionManager cannot. **VERIFY**
- **R-LIQ-5** `donate` is not restricted.
- **R-LIQ-6** The hook MUST NOT call `modifyLiquidity` (including a zero-delta fee poke) on a position whose recorded liquidity is zero. **VERIFY** that v4 reverts on updating an empty position.

## 5. Oracle

- **R-ORC-1** The hook MUST keep a running accumulator `(lastSwapTs, lastTick, cumulative)`. At the start of every `beforeSwap` whose `block.timestamp` differs from `lastSwapTs`, it MUST set `cumulative += preSwapTick × (now − lastSwapTs)`, then `lastSwapTs = now` and `lastTick = preSwapTick`, where `preSwapTick` is the PoolManager's `slot0.tick` read before the swap executes. A snapshot `(now, cumulative)` MUST additionally be appended to the ring buffer if at least `observationInterval` seconds have passed since the previous snapshot. Only the ring-buffer snapshots are rate-limited; the accumulator is never skipped (ADR-013).
- **R-ORC-2** `twapTick(window)` MUST equal `(cumulativeNow − cumulativeAt(now − window)) / window` rounded toward negative infinity.
- **R-ORC-3** The cumulative at query time `now` MUST be `cumulative + currentTick × (now − lastSwapTs)`, using the PoolManager's current tick; this value is exact. The cumulative at a snapshot timestamp is exact. For a query time strictly between two snapshots, the cumulative MUST be linearly interpolated, which is exact only if no swap occurred between those snapshots; the resulting TWAP error bound is stated in MATH §4.
- **R-ORC-4** If the oldest retained snapshot is newer than `now − window`, the oracle MUST use the oldest snapshot and report `warm = false` for that window. The oracle is **warm** for the stress machine iff the anchor window is fully covered, which implies the short window is covered.
- **R-ORC-5** Cardinality is fixed at construction and MUST be at least `ceil(anchorWindow / observationInterval) + 1` (the hard minimum). A factor of 1.1 above that is the recommended default.

## 6. Stress machine

States: `CALM`, `STRESS`, `RECOVERING`. Let `dev = collateralIsCurrency0 ? (A − S) : (S − A)` in ticks.

- **R-STR-1** CALM → STRESS when `dev ≥ stressEnterTicks` and the oracle is warm. On entry the hook MUST record `stressStartedAt = now`. `stressStartedAt` is set on this transition only (ADR-019).
- **R-STR-2** STRESS → RECOVERING when `dev < stressExitTicks`. RECOVERING → STRESS when `dev ≥ stressEnterTicks`; this transition MUST NOT change `stressStartedAt`, otherwise a relapse could extend the lock indefinitely against R-STR-5.
- **R-STR-3** RECOVERING → CALM when `dev < stressExitTicks` has held continuously for `calmDuration`.
- **R-STR-4** The lock is active while the state is not CALM and `now < stressStartedAt + maxStressLock`.
- **R-STR-5** After the lock expires, it MUST NOT re-arm until the state has returned to CALM at least once.
- **R-STR-6** While the oracle is not warm (R-ORC-4) the state MUST remain CALM.
- **R-STR-7** Evaluation MUST run (a) in `beforeSwap` at most once per `observationInterval`, (b) at the start of every state-changing external function that reads or acts on the lock state, including `claimRedeem`, so that no separate poke is needed to release a lock, and (c) in `pokeStress()`. The transition function MUST be pure. View functions MUST compute the lock state by applying that pure function to current inputs without writing state.
- **R-STR-8** Threshold conversion from bps to ticks MUST round to nearest and be documented in MATH.
- **R-STR-9** Accepted approximation: continuity of the below-exit period required by R-STR-3 is checked only at evaluation points. A deviation spike that begins and ends between two evaluations is not seen. Documented in THREAT_MODEL T3/T4.

### 6.1 Function availability by state

| Function | CALM | STRESS / RECOVERING, lock active | Stressed, lock expired |
|---|---|---|---|
| `createVault` | yes | yes (empty vault) | yes |
| `seed` | yes | no | no |
| `deposit` | yes | no | no |
| `requestRedeem`, `cancelRedeem` | yes | yes | yes |
| `claimRedeem` | yes, if matured | no | yes, if matured |
| `rerange` | yes | no | no |
| `deployIdle` | yes | yes | yes |
| `setCommitment` | yes | yes | yes |
| `checkpoint`, `flagBreach`, `pokeStress` | yes | yes | yes |
| `claimCuratorFees` | yes | yes | yes |
| `fundStandby`, `setStandbyRate` | yes | yes | yes |

`rerange` is CALM-only in every stress case. Liquidity can be added during stress only through `deployIdle` (ADR-017).

Blocked calls MUST revert with `StressLockActive(until)` where applicable, or `NotCalm()` for calls blocked outside CALM after lock expiry.

## 7. Vaults

### 7.1 Creation
- **R-VLT-1** `createVault` MUST revert if `vaultCount == MAX_VAULTS`, if there are zero or more than `MAX_POSITIONS` ranges, if any range is misaligned to tick spacing, out of tick bounds, inverted or duplicated, or if `curatorFeeBps > maxCuratorFeeBps`. The caller becomes the curator. Ranges are stored but no liquidity exists until the first deposit.

### 7.2 Deposit
- **R-VLT-2** `deposit` MUST evaluate stress, run `_checkpoint`, then revert if the state is not CALM or if a swap has occurred in the same transaction.
- **R-VLT-3** For `shares > 0` and `supply > 0`, per-position liquidity added MUST be `ceilDiv(L_i × shares, supply)` and the idle slice per currency MUST be `ceilDiv(idle × shares, supply)`.
- **R-VLT-4** The depositor MUST pay exactly the PoolManager-reported amounts plus idle slices; the call MUST revert if either exceeds its `amountMax` (`SlippageExceeded`).
- **R-VLT-5** The first deposit into a vault is `seed`. It MUST be callable only by the vault's curator (`NotCurator`); its `receiver` MAY be any address. It MUST mint `INITIAL_SHARES` to the receiver and burn `MINIMUM_SHARES` to the zero address. Initial liquidity per position is supplied by the curator through a per-position liquidity argument (see CONTRACTS). `deposit` on an unseeded vault MUST revert (`VaultNotSeeded`).
- **R-VLT-6** Share accounting MUST NOT read any token `balanceOf`, spot price or oracle price.

### 7.3 Redeem
- **R-VLT-7** `requestRedeem(vaultId, shares)` MUST move `shares` from the caller to hook escrow and create a ticket owned by the caller with `maturity = now + exitNotice`. A ticket carries no receiver. Escrowed shares remain in `supply` and keep earning and bearing risk. Escrowed shares MUST NOT be transferable.
- **R-VLT-8** `claimRedeem(ticketId, receiver)` MUST be callable only by the ticket owner or by an address for which `isOperator(owner, caller)` holds (`NotTicketOwnerOrOperator`). It MUST evaluate stress, then revert before maturity (`TicketNotMature`) or while the lock is active. It MUST run `_checkpoint`, remove `floorDiv(L_i × shares, supply)` liquidity from each position, add the floor idle slice, burn the shares and send tokens to `receiver`. The receiver is chosen at claim time, so a receiver that cannot accept tokens never traps funds.
- **R-VLT-9** `cancelRedeem` MUST return escrowed shares to the ticket owner.

### 7.4 Re-range, idle deployment, commitment
- **R-VLT-10** `rerange` MUST be callable only by the curator, only when the state is CALM and no swap occurred in the transaction. It removes all liquidity, then adds the new ranges using recovered tokens and idle, in one `unlock`. After it, `D_v ≥ K_v` MUST hold or the call reverts (`CoverageBelowCommitment`). Standby accrual for the interval MUST use `min(depthBefore, depthAfter)`.
- **R-VLT-11** `deployIdle` MUST be callable only by the curator, in any state, and MUST only use idle balances. It MUST NOT reduce liquidity anywhere.
- **R-VLT-12** `setCommitment` increases take effect immediately. Decreases MUST set `pendingCommitment` and take effect at `now + exitNotice`.
- **R-VLT-13** Tokens that cannot be placed after a re-range remain in `idle`.
- **R-VLT-14** `rerange` MUST revert outside CALM (`NotCalm` / `StressLockActive`). There is no additive re-range mode; additions during stress use `deployIdle` (R-VLT-11).

## 8. Coverage and breach

- **R-COV-1** In CALM, if `D_v < K_v` after anchor drift, the curator has `rerangeGrace` to restore coverage.
- **R-COV-2** After the grace, anyone MAY call `flagBreach(vaultId)`. It MUST record `breachSince`, increment `breachCount`, and stop standby accrual for the vault.
- **R-COV-3** A breach MUST clear automatically at the next checkpoint or re-range where `D_v ≥ K_v` again.
- **R-COV-4** Coverage MUST NOT be enforced while the lock is active.

## 9. Standby fund

- **R-SBY-1** The standby reward is paid in the quote currency. The sponsor is an immutable address.
- **R-SBY-2** `fundStandby(amount)` MUST pull `amount` of quote from the sponsor and hold it as PoolManager claims. `setStandbyRate(rate)` MUST revert if `rate > maxStandbyRate`.
- **R-SBY-3** At each checkpoint: `interval = min(now − lastCheckpoint, maxAccrualInterval)`; the depth sample is `d = min(D_v, Λ_v)` where `D_v` is anchor-based committed depth and `Λ_v` is the vault's live absorbable depth measured from current spot over `bandBps` of price impact (MATH §7); `eligible = min(d_start, d_now, K_v)` in every state including STRESS and RECOVERING; `reward = floor(eligible × rate × interval / RATE_SCALE)` using 512-bit-safe multiplication; `reward` MUST be capped by the fund balance and be zero if the vault is in breach.
- **R-SBY-4** Credited reward MUST split into `curatorFeeBps` to `curatorOwed` and the remainder to the vault's `idle` quote balance.
- **R-SBY-5** Every function that changes a vault's share supply or positions MUST checkpoint before the change.
- **R-SBY-7** Sponsor funds are not withdrawable in v1. The sponsor stops spending by setting the rate to zero and should fund in tranches. Documented in SECURITY and ECONOMICS (ADR-021).
- **R-SBY-6** When the fund reaches zero the hook MUST emit `StandbyDepleted` once and stop crediting. Lock and queue rules are unaffected.

## 10. Trading fees and curator pay

- **R-FEE-1** Position fees MUST be crystallized by a zero-liquidity poke before any change to a vault's shares or liquidity. Fees MUST be taken from `feesAccrued`, never inferred from `callerDelta`.
- **R-FEE-2** The curator share is `curatorFeeBps` of crystallized fees and of standby rewards. It never applies to principal.
- **R-FEE-3** `claimCuratorFees` MUST pay only `curatorOwed` to the curator's chosen recipient.

## 11. Views

- **R-VIEW-1** `committedDepth()` MUST sum `min(D_v, K_v)` over vaults not in breach.
- **R-VIEW-2** `liveDepth(impactBps, horizon)` MUST measure from current spot, over all pool liquidity, rounded down. Because of G-1 all pool liquidity is vault liquidity, so it MUST be computed by iterating every vault's positions (bounded by R-VIEW-4), never by scanning ticks. It MUST subtract for each vault the fraction of shares in tickets whose effective exit time `max(maturity, lockedUntil)` is `≤ now + horizon`.
- **R-VIEW-3** `lockState()` MUST return the current state and, if the lock is active, `lockedUntil = stressStartedAt + maxStressLock`.
- **R-VIEW-4** All views MUST be bounded by `MAX_VAULTS × MAX_POSITIONS` iterations.
- **R-VIEW-5** `liveDepth` is the figure risk consumers SHOULD use to size caps. `committedDepth` is for coverage and reward accounting and does not net exits or measure from spot.

## 12. Same-transaction guards

- **R-TX-1** `beforeSwap` MUST set a transient `SWAPPED` flag and revert if `VAULT_OP` is set.
- **R-TX-2** `seed`, `deposit`, `claimRedeem`, `rerange` and `deployIdle` MUST set `VAULT_OP` and revert if `SWAPPED` is set.
- **R-TX-3** All state-changing external functions that unlock MUST be non-reentrant via a transient guard.

## 13. Access control

| Capability | Who |
|---|---|
| Create vault | Anyone |
| Seed, re-range, deploy idle, set commitment, claim curator fees | The vault's curator |
| Fund standby, set standby rate | The sponsor (immutable) |
| Deposit, request/cancel redeem | Share holders |
| Claim redeem | Ticket owner or an operator approved by the owner, to a receiver chosen at claim time |
| Checkpoint, flag breach, poke stress | Anyone |
| Move or freeze funds in any other way | Nobody (R-ACL-1) |

- **R-ACL-1** There MUST be no owner, pauser, upgrade path or function that lets any address redirect vault funds outside these rules.

## 14. Configuration bounds

Constructor MUST revert with `InvalidConfig` unless: `100 ≤ bandBps ≤ 2500`; `50 ≤ stressEnterBps < bandBps`; `stressExitBps < stressEnterBps`; `anchorWindow ≥ 1 h`; `5 min ≤ shortWindow < anchorWindow`; `calmDuration ≥ shortWindow`; `maxStressLock ≤ 7 d`; `exitNotice ≤ 3 d`; `rerangeGrace ≥ observationInterval`; `maxAccrualInterval ≥ observationInterval`; `maxCuratorFeeBps ≤ 5000`; `observationCardinality ≥ ceil(anchorWindow / observationInterval) + 1`; `collateral != quote`; neither is zero; `initializer != address(0)`; `fee` is a static fee not exceeding the PoolManager maximum and not the dynamic-fee flag; `tickSpacing` lies within the PoolManager's bounds (**VERIFY** constants in `TickMath`).

## 15. Edge cases

| Case | Required behaviour |
|---|---|
| No swaps for a long time | Oracle exact (price constant); stress not re-evaluated until a touch or `pokeStress` |
| Oracle not warm | State CALM; accrual continues; `lockState` reports CALM with warm = false |
| Vault supply equals only the burned minimum | Redeem reverts (`ZeroShares`); depth is zero |
| Redeem of all escrowed shares | Allowed; vault may fall below commitment (breach path) |
| Fund empty | Accrual zero, `StandbyDepleted` emitted once |
| Token transfer reverts on payout | Whole transaction reverts; funds stay in the vault |
| Re-range with unplaceable tokens | Remainder stays in idle |
| Position liquidity rounds to zero on redeem | Dust stays in the vault |
| Tick spacing 1 vs large | Behaviour identical; ranges aligned to spacing |
| Spot outside every position | Live depth zero; committed depth unaffected; eligible depth zero, so no reward accrues |
| Position with recorded liquidity zero | The hook MUST NOT poke or modify it (R-LIQ-6) |
| Matured tickets exit at crash onset before the lock engages | Allowed; documented as T18; quantified by the `ExitRace` scenario |

## 16. Compliance matrix

Each requirement ID MUST map to at least one test. `docs/TESTING.md` §6 holds the table; CI MUST fail if a requirement has no test reference (`@custom:requirement R-…` tag in test NatSpec).
