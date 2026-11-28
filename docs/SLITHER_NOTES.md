# Slither notes

Slither 0.11.4 (installed locally in a Python venv; also run in CI). Command: `slither . --config-file slither.config.json` (`lib/`, `test/` and `script/` are filtered). Every finding is either fixed or justified here.

## 2026-11-25 (M0)

| Detector | Location | Decision |
|---|---|---|
| `cyclomatic-complexity` (informational) | `ConfigLib.validate` (complexity 18) | Accepted. The function is a flat list of independent bound checks (SPEC §14, R-CFG-1), each covered on both sides by `ConfigLib.t.sol`. Splitting it would only scatter the bounds without reducing risk. |

## 2026-11-25 (end of M1)
Slither 0.11.4, same command. Two informational findings, no others across all six libraries and the stub hook.

| Detector | Location | Decision |
|---|---|---|
| `cyclomatic-complexity` | `ConfigLib.validate` (18) | Accepted, see M0. |
| `cyclomatic-complexity` | `StressMachine.next` (12) | Accepted. The state machine is a single decision table over (state, deviation class) whose branches are each covered by unit tests, a sequence-fuzz reference model and mutation tests (docs/MUTATION_LOG.md). Splitting it would hide the transition table SPEC §6 specifies. |

## 2026-11-26 (M2)
Slither 0.11.4, `slither . --config-file slither.config.json --fail-low`. The first GitHub run failed because Slither exits non-zero on any finding; CI now fails on low and above only, and every medium/low finding below is justified inline with `// slither-disable-*` next to the code. Remaining informational output: 6 findings.

| Detector | Location | Decision |
|---|---|---|
| `unused-return` (medium, inline-disabled) | `BallastHook` `getSlot0` tuple reads, `Observations.update` in `pokeStress`, `twapTick`/`twapTickHinted` partial tuple reads | Intentional: only the tick (or only part of the tuple) is needed. |
| `incorrect-equality` (medium, inline-disabled) | `BallastHook._evaluateStress` enum comparisons | Enum equality is exact by construction; no balance or timestamp equality. |
| `timestamp` (low, disabled around `_previewStress`/`_evaluateStress`) | same | The flagged comparisons are on enums and booleans; time-dependent maths is in the libraries and is not used as a precise gate or for randomness. |
| `assembly` (informational) | `Transient.get/set` | Two documented one-opcode helpers (`tload`/`tstore`); no compiler support for `transient` state variables in 0.8.26. |
| `cyclomatic-complexity` (informational) | `ConfigLib.validate` (18), `StressMachine.next` (12), `HookPermissions.flags` (15) | Accepted: flat lists of independent checks or a decision table, each branch covered; splitting would scatter them. |
| `dead-code` (informational) | `BallastHook._enterVaultOp` | Accepted until M3: the guard helper (and `nonReentrant`) are introduced in M2 as the plan approved and are exercised by tests through the test-only subclass; M3's `seed`/`deposit`/`claimRedeem`/`rerange`/`deployIdle` are their first production callers. Remove this entry in M3. |


## 2026-11-27 (M8 start: CI had been failing since the vaults split)
Slither 0.11.4, `slither . --config-file slither.config.json --fail-low`. The CI job failed on 12 detector groups (medium and low). All are resolved below; the command now exits 0. Remaining output is informational only: `assembly`, `cyclomatic-complexity`, `dead-code`.

**Limitation (read first).** Slither prints `Impossible to generate IR` for `BallastVaults.createVault`, `_opRerange` and `_opDeploy` (all three build a `Position(...)` struct for a push; the previous commit behaves the same). Slither therefore analyses those three functions only partially. Mitigation: they are exercised by the unit suites, the handler-based invariants, the mutation runner (`docs/MUTATION_LOG.md`) and the access-control audit (INV-13). The two false positives this causes are listed.

| Detector | Location | Decision |
|---|---|---|
| `uninitialized-state` (high) | `BallastVaults._vaults`, `_buckets` | False positive from the limitation above: both mappings are written through `storage` pointers and in `createVault`. Inline-disabled with the reason at the declaration. |
| `incorrect-equality` (medium) | `BallastHook._earliestRelease` | Enum equality and a zero sentinel (`belowExitSince != 0`), not a balance or time equality. Inline-disabled. |
| `uninitialized-local` (medium) | accumulators in `_opAdd`, `_opRedeem`, `_opRerange`, `_accrue`; `OpCtx c` in `claimCuratorFees` | Intended zero start. `BallastDepth.shrinkLiquidity` and `BallastLens._preview` now initialise with `= 0`. In `BallastVaults` the initialisers cost 31 bytes under `via_ir`, so those carry an inline disable (ADR-060). |
| `unused-return` (medium) | `BallastStandby.fundStandby` (`unlock`), `accrue` (`transfer`), `BallastVaults._rawModify`, `BallastLens` partial `getSlot0` reads | `unlock` returns the callback's empty bytes; `transfer` returns `true` or reverts (the PoolManager's ERC-6909); `_rawModify` returns the result to its caller (Slither reports it only because of the limitation above); the `getSlot0` reads need only some fields. Inline-disabled with reasons. `BallastLens.lockState` now assigns its tuple explicitly. |
| `missing-zero-check` (low) | `BallastStandby` constructor, `vaults_` | Only `BallastVaults` constructs the standby and passes `address(this)`. Inline-disabled. |
| `calls-loop` (low) | `BallastVaults._rawModify`, `BallastLens._supply`, `_slots` | One PoolManager call per position, bounded by `MAX_POSITIONS` (8) per operation; the lens loops are view-only and bounded by `MAX_VAULTS x MAX_POSITIONS` (R-VIEW-4). Inline-disabled. |
| `reentrancy-benign`, `reentrancy-events` (low) | `BallastVaults._accrue`; `requestRedeem`; `BallastStandby.fundStandby`, `accrue` | `requestRedeem`, `fundStandby` and `accrue` now write state and emit before their single external interaction (ADR-060). `_accrue` calls `standby.accrue`, an immutable sibling callable only by the vaults whose only external call is an ERC-6909 `transfer` on the PoolManager (no receiver hook); it cannot re-enter. Inline-disabled around `_accrue`. |
| `timestamp` (low) | `BallastLens.liveDepth`, `exitingShares`, `_exiting` | View-only comparison of a maturity or release time with the netting horizon; not a precision gate and not randomness. Inline-disabled. |
| `dead-code` (informational) | `BallastVaults._coverShortfall`, `_requireBound`, `_settleNet`, `_shrink` | False positive from the limitation: `createVault` calls `_requireBound`, `_opRerange` calls the other three. |
| `assembly` (informational) | `Transient.get/set`, `BallastVaults.extsload` | Documented one-opcode helpers; `extsload` is the lens's read primitive (ADR-050). |
| `cyclomatic-complexity` (informational) | `ConfigLib.validate`, `HookPermissions.flags`, `StressMachine.next` | Accepted, see M0 to M2. |

## 2026-11-28 re-run

Re-ran the CI command exactly: `slither . --config-file slither.config.json --fail-low` with Slither 0.11.4. Exit status 0;
no low, medium or high findings. The same three IR-generation limitations and the same informational `assembly`,
`cyclomatic-complexity` and `dead-code` findings above remain.
