# Progress

**Read with `CLAUDE.md`. A fresh session can resume from these two files alone.**

## Current milestone
M3 (vault lifecycle) in progress, with M4–M7 logic written in the same `BallastHook` pass (re-range, stress gate on the queue, standby accrual, exit buckets). Nothing from M3 onward is committed yet except the pre-registration.

## Done
- M0–M2 accepted by the maintainer.
- `analysis/PREREGISTRATION.md` and `analysis/vectors/s1_path.json` committed before any simulation code (commit f3d4a05). Do not edit.
- SPEC: R-STR-3 / R-STR-3a sentences added (calm interruption and STRESS-between-thresholds).
- `BallastHook` vault logic written: `createVault`, `seed`, `deposit`, `requestRedeem`, `claimRedeem`, `cancelRedeem`, `rerange`, `deployIdle`, `setCommitment`, `claimCuratorFees`, `checkpoint`, `flagBreach`, `fundStandby`, `setStandbyRate`, exit buckets and `exitingShares`.

## BLOCKED: decision needed from the maintainer (bytecode size)
The M3-M7 vault logic written into `BallastHook` makes the runtime bytecode **46,073 bytes** (legacy pipeline, `optimizer_runs = 1`) or **40,563 bytes** (`via_ir`, `optimizer_runs = 200`); the limit is 24,576. The M2 hook alone was 13.5 KB. Ablation (each function stubbed to a revert) shows no single hog: each operation costs 1-3 KB and each external function or view about 0.5 KB, so trimming cannot close a 16 KB gap. A second contract is needed, which changes D-3/G-1/INV-1 wording. Work-in-progress is on branch `wip/m3-vault-core` (does not build within the size limit; tests not yet updated).

## Open doubts
- Bytecode size: 40.5 KB at `optimizer_runs = 200` with `via_ir` (limit 24.576 KB). Being reduced; see DECISIONS ADR-047 once settled.
- `StressInfo.earliestUnlock` and bucketed exit netting are spec refinements (ADR-045).

## Next
1. Get the hook under the size limit.
2. Update the test harness and existing tests, then write M3 unit/fuzz tests and invariants INV-1…5.
3. M4 → M11 per the maintainer's priority order.

## Resume commands
```
git status && forge build --sizes && forge test --no-match-path "test/fork/*"
python3 tools/compliance.py
```
