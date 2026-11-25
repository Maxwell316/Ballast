# Ballast Simulation and Evaluation Protocol

**Status:** Draft v0.1 · Defines how Ballast is compared with an ordinary pool under stress. **No results appear in this document until they are produced by the scripts and logged in `analysis/results/`.** Do not invent or extrapolate numbers.

---

## 1. Question

Under the same liquidity, the same price shock and the same liquidation-sized sell, how does a Ballast pool compare with an ordinary v4 pool (control) on execution quality, depth availability and LP exit behaviour, and do the lock and notice rules behave as specified?

## 2. Design

- **Treatment:** Ballast pool with two curator vaults (different bands and commitments), standby funded.
- **Control:** ordinary v4 pool, no hook, same pair, fee tier and tick spacing, with liquidity placed at the same ranges and amounts as the Ballast vaults.
- **Same shocks:** identical swap sequences are replayed against both pools in the same order by the same router.
- **Environments:**
  - `prodlike` in Foundry (time warped): primary evidence for time-based behaviour.
  - `demo` on the public testnet: end-to-end proof of deployment, with compressed windows.

## 3. Scenarios

| ID | Name | Description | Targets |
|---|---|---|---|
| S1 | Crash | Price falls through the band over a stated duration, a liquidation-sized collateral sell executes mid-crash, then partial recovery | Slippage, depth remaining, lock timing |
| S2 | Slow bleed | Gradual decline that moves the anchor along; no sudden stress | Coverage drift, breach flow, accrual, no false lock |
| S3 | Whipsaw | Rapid down-up moves that cross thresholds repeatedly | Hysteresis, no re-arm, lock expiry |
| S4 | Manipulation | Attacker pushes price to try T3/T4/T5/T6 | Mitigation effectiveness, attacker cost |
| S5 | Drought | Sponsor stops funding; exits mature | Depth-view decay, `StandbyDepleted` once |

For each scenario, the price path, swap sizes, durations and actor behaviour are fixed in the pre-registration (§5).

## 4. Metrics

**Execution quality (liquidation sell)**
- Average execution price versus pre-shock spot, in bps.
- Price impact: final price versus pre-sell price, in bps.
- Fraction of the sell filled before price reaches the band edge.

**Depth**
- `liveDepth(impactBps, horizon)` before, during and after the shock for several horizons.
- Depth remaining in the control pool, measured the same way (sum of absorbable collateral over positions, since the control has no lens).

**Exit behaviour**
- Number and timing of exit attempts blocked during stress (Ballast) versus succeeded (control).
- Exit attempts that succeed after calm or after `maxStressLock` expiry.

**LP outcomes (reported, not spun)**
- Final token holdings per LP and value at the post-shock price, in both pools. Report losses plainly. Ballast locks risk in place and does not protect LPs from price loss.

**Protocol behaviour**
- State transition timeline; lock violations (must be zero); standby credited; coverage uptime; breaches.

## 5. Pre-registration

Create and commit `analysis/PREREGISTRATION.md` **before** running anything. It states:
1. Scenario definitions: price paths, durations, swap sequences, liquidity layouts, parameters (`prodlike` and `demo`).
2. The liquidation-sized sell, in collateral units and as a percentage of committed depth.
3. Metrics and how each is computed (formulas or code references).
4. **Pass/fail bar** (set by the human; Q-5). Suggested structure:
   - Safety: zero lock violations; no exit executes while the lock is active.
   - Execution: Ballast's price impact on the liquidation sell is no worse than the control's, with a stated improvement target if one is claimed.
   - Behaviour: transitions match the reference table-driven model across all scenarios.
5. What will be reported if the bar is missed (everything, unchanged).

Do not modify the scenarios or the bar after seeing any result. If a mistake is found, add a dated amendment explaining it and rerun, keeping the original results visible.

## 6. Procedure

1. Implement scenarios as Foundry scenario tests (`prodlike`) emitting JSON results via `vm.writeJson` into `analysis/results/`.
2. Implement `script/RunCrash.s.sol` to replay S1 on the public testnet pair (Ballast pool and control) using the `demo` profile.
3. Record all transaction hashes in `deployments/<chainId>.json`.
4. Generate tables with `analysis/report.py` (or a Foundry script) from JSON only, with no manual edits.
5. Summarize in the section below and in the README with the pre-registered bar stated alongside.

## 7. Results (filled from `analysis/results/` only)

| Scenario | Metric | Control | Ballast | Bar | Met? |
|---|---|---|---|---|---|
| S1 | Price impact of liquidation sell (bps) | _pending_ | _pending_ | _pending_ | _pending_ |
| S1 | Exit attempts executed during lock | _pending_ | _pending_ | 0 | _pending_ |
| … | … | … | … | … | … |

## 8. Threats to validity

- Synthetic price paths are not real markets. State that results are mechanism demonstrations.
- Mock tokens and a simple router may not represent real liquidation routing.
- The control mirrors liquidity layout but not LP behaviour: in reality LPs may exit.
- Compressed demo windows may exaggerate or hide effects.
- Small pools exaggerate price impact differences.
- Single-run results lack variance; for stochastic paths report multiple seeds.

## 9. Reproducibility

- Pin dependency versions and commit hash in each results file.
- Include seeds, parameters and profile name in every JSON.
- Provide a single command (`make sim` or documented `forge` invocations) that regenerates all results.
