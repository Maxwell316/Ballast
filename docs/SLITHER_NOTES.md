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
