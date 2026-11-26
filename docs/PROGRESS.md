# Progress

**Read with `CLAUDE.md`. A fresh session can resume from these two files alone.**

## Current milestone
M3 in progress on branch `wip/m3-vault-core` (not mergeable yet: over the size limits). `main` holds M0-M2 plus the pre-registration only.

## Done
- ADR-045..049 and doc patches for the split (committed on the branch): SPEC, CONTRACTS (function table), ARCHITECTURE, THREAT_MODEL (T1, T19), TESTING, DEPLOYMENT, README, CLAUDE.md, MATH §5a.
- Code split: `BallastHook` (callbacks, oracle, stress, gate, `enterVaultOp`, `evaluateStress`), `BallastVaults` (custody and all vault operations), `BallastStandby` (fund, rate, accrual).
- M2 tests adapted to the new structure (harness no longer has any liquidity path; liquidity goes through the real vaults via `_provide`). Not yet re-run.

## BLOCKED: size decision needed (see ADR-046 table)
- Vaults runtime 28,959 B (via_ir) vs the 23,800 target: 5.2 KB over.
- Hook initcode 53,457 B vs EIP-3860 49,152: over, because it embeds vaults + standby creation code. Even at the runtime target the margin would be under 3 KB.

## Next
1. Maintainer decision on the size options.
2. Run and fix the adapted M2 tests; write the M3 tests.
3. Continue M3..M11.

## Resume commands
```
git checkout wip/m3-vault-core && forge build --sizes && forge test --no-match-path "test/fork/*"
```
