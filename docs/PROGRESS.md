# Progress

**Read with `CLAUDE.md`. A fresh session can resume from these two files alone.**

## Current milestone
M8 hardening is complete locally, including the continuation checks below. M9 deployment workflow and M10 simulation remain. Continuous mode (ADR-045..058).

## Done
- M0-M2, the S1 pre-registration (`analysis/PREREGISTRATION.md`, never edit) and the split custody (hook, vaults, shares, standby, depth, lens, advisor).
- M3-M6 suites: lifecycle, re-range, commitment, breach, standby accrual, `deployIdle`, the Crash scenario; invariants INV-1..4, 6, 8, 10, 12; access control (INV-13); hostile-token reentrancy; binding (T20); edge cases; lens layout; vault gas; sizes.
- Mutation testing: 17 of 17 vault, standby and lens mutations caught (`docs/MUTATION_LOG.md`).
- ADR-058: the lens derives the liquidation direction from the config, not from the hook's binding state.
- M8: invariants INV-1..12, 14, 15 in a Matrix handler suite; Manipulation (T3-T6), ExitRace (T18), AttackerMocks (T13, T2, T19); mutation log updated.
- Fresh non-fork suite after the invariant matrix edit, Crash consumer assertion, and Breach/Drought scenarios: 568 passed, 0 failed, 3 skipped.
- Fork suite against Unichain Sepolia: 13 passed, 0 failed (2026-11-28).
- Gas snapshot regenerated from the final M8 test tree: 568 passed, 0 failed, 3 skipped; `.gas-snapshot` includes Breach/Drought scenarios.
- Slither 0.11.4 with CI flags (`--fail-low`): exit 0, no low-or-higher findings; existing IR limitations and informational findings are documented.
- `forge fmt --check` passes after the changes. `tools/compliance.py --check`: 85 of 86 IDs tested, one guidance waiver (R-VIEW-5).
- CI coverage command and coverage gate pass on the final M8 test tree: 402 tests, 99.1% source lines and 96.8% branches.
- `forge build --sizes --skip "test/**" --skip "script/**"` passes; `BallastVaults` runtime is 24,269 bytes (307 bytes below EIP-170 and within the 24,300-byte project ceiling).
- `docs/storage-layout.md` generated from `forge inspect BallastVaults storage-layout --json`; struct packing was checked against compiler metadata.
- Lens independence audit table and both-direction binding/order audit added to `docs/TESTING.md`; Crash includes an advisor/live-depth assertion; consumer guidance and waiver text clarified; the curator-authorization mutation was caught by two focused access-control tests.
- `Breach.t.sol` and `Drought.t.sol` now contain readable scenario tests across all four collateral-order/lens-construction variants; each focused suite passes (8 tests each). Drought assertion follows the documented early-conservative exit-bucket rounding.
- Sizes: vaults runtime 24,268 bytes (ceiling 24,300, margin test in `test/unit/Sizes.t.sol`). Further growth needs the pre-authorised cuts: (c) `deployIdle`, then (d) `cancelRedeem`, each with an ADR.

## Remaining
1. The CI-profile invariant suite (1024 × 256) did not finish in the local environment and was stopped after more than an hour; it needs a controlled rerun.
2. M9: add the pool creation, seeding, standby-funding and crash-replay scripts and smoke checks; update deployment docs for the split architecture. A broadcast remains a human action; no funded deployment or manifest address has been supplied.
3. M10: implement the registered simulation scenarios and runner; report generated evidence only. Do not edit `analysis/PREREGISTRATION.md`.

## Gotchas
Under `via_ir` read time with `vm.getBlockTimestamp()` (ADR-054). `vm.prank` and `vm.expectRevert` apply to the next external call, so cache getter results first. Use `vm.expectPartialRevert` for errors with arguments. Do not edit `src/` or `test/` while `tools/mutate.py` runs, and do not use `pgrep -f` in a shell whose own command line contains the pattern.

## Resume commands
```
git checkout main && forge build --sizes --skip "test/**" --skip "script/**" && forge test --no-match-path "test/fork/*"
RPC_URL=https://sepolia.unichain.org forge test --match-path "test/fork/*"
```
