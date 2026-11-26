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

