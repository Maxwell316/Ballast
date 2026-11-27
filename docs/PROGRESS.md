# Progress

**Read with `CLAUDE.md`. A fresh session can resume from these two files alone.**

## Current milestone
M8 (hardening) test work complete and verified locally; docs and M8 report in progress. M9 next. Continuous mode (ADR-045..058).

## Done
- M0-M2, the S1 pre-registration (`analysis/PREREGISTRATION.md`, never edit) and the split custody (hook, vaults, shares, standby, depth, lens, advisor).
- M3-M6 suites: lifecycle, re-range, commitment, breach, standby accrual, `deployIdle`, the Crash scenario; invariants INV-1..4, 6, 8, 10, 12; access control (INV-13); hostile-token reentrancy; binding (T20); edge cases; lens layout; vault gas; sizes.
- Mutation testing: 17 of 17 vault, standby and lens mutations caught (`docs/MUTATION_LOG.md`).
- ADR-058: the lens derives the liquidation direction from the config, not from the hook's binding state.
- M8: invariants INV-1..12, 14, 15 in a Matrix handler suite; Manipulation (T3-T6), ExitRace (T18), AttackerMocks (T13, T2, T19); mutation log updated.
- 536 tests pass (2026-11-27, `forge test --no-match-path "test/fork/*"`); `tools/compliance.py --check`: 85 of 86 IDs tested, one waiver (R-VIEW-5).
- Sizes: vaults runtime 24,268 bytes (ceiling 24,300, margin test in `test/unit/Sizes.t.sol`). Further growth needs the pre-authorised cuts: (c) `deployIdle`, then (d) `cancelRedeem`, each with an ADR.

## Next
1. M7 leftover: `docs/storage-layout.md` from `forge inspect`.
2. M8 leftovers: `Drought.t.sol` and `Breach.t.sol` scenarios (CLAUDE.md §9.1; the flows are unit-tested but the scenario files do not exist), verify the lighter coverage setup in CI after pushing, `forge snapshot`, the M8 report.
3. M9 deploy scripts (SeedVaults, FundStandby, CreatePool, RunCrash) and smoke tests; the user broadcasts.
4. M10 simulation per `analysis/PREREGISTRATION.md`; M11 docs polish.

## Gotchas
Under `via_ir` read time with `vm.getBlockTimestamp()` (ADR-054). `vm.prank` and `vm.expectRevert` apply to the next external call, so cache getter results first. Use `vm.expectPartialRevert` for errors with arguments. Do not edit `src/` or `test/` while `tools/mutate.py` runs, and do not use `pgrep -f` in a shell whose own command line contains the pattern.

## Resume commands
```
git checkout main && forge build --sizes --skip "test/**" --skip "script/**" && forge test --no-match-path "test/fork/*"
RPC_URL=https://sepolia.unichain.org forge test --match-path "test/fork/*"
```
