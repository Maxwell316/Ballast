# Mutation sanity log

After each library's tests pass, a scratch change breaks one rounding direction, bound or comparison; at least one test must fail. The change is then reverted (the working tree is checked clean). Procedure and tooling: TESTING §4a.

## ConfigLib (M0)
Not mutated in M0: every bound is tested on both sides, and `testFuzz_Validate_NeverAcceptsCardinalityBelowMinimum` covers the ceiling formula. (Mutation of ConfigLib may be added with the M2 hook tests.)

## BandMath (M1)
| Mutation | Result |
|---|---|
| `EPS_WAD = 0` (no conservative bias) | Caught by `test_BpsToTicksWad_NeverExceedsReference_AndStaysWithinBias` |
| `EPS_WAD = 1e12` (bias too large) | Caught by `test_BpsToTicksWad_NeverExceedsReference_AndStaysWithinBias` |
| `bpsToTicksDown` rounds up | Caught by `test_BpsToTicksDown_SatisfiesPostconditionForAllBps`, `test_KnownValues_750Bps` |
| `bpsToTicksNearest` floors instead of rounding | Caught by `test_BpsToTicksNearest_EqualsRoundedReferenceForAllBps`, `test_KnownValues_750Bps` |
| Band direction swapped in `bandEdges` | Caught by `test_BandEdges_BothDirections_AllScenarios`, `test_BandEdges_ClampToTickBounds` |
| Lower clamp removed | Caught by `test_BandEdges_ClampToTickBounds` |
| Upper clamp removed | Caught by `test_BandEdges_ClampToTickBounds` |
| `bps >= 10_000` cap changed to `>` | Caught by `test_Edges_ZeroAndBeyondRange` |

Two first-round findings were fixed before the final run: the bias-size test compared against the (mutated) constant itself, so `EPS_WAD = 1e12` survived until it used a literal; and the nearest-rounding table check was too loose (±1 tick) to detect floor-vs-round, so it now requires exact equality (which holds for all 2,500 values).
