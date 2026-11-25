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

## VaultMath (M1)
| Mutation | Result |
|---|---|
| `ceilShare` rounds down | Caught by `testFuzz_MatchesFullMath_AndBracketsExactValue`, `testFuzz_RoundingFavoursVault`, `test_Examples` |
| `floorShare` rounds up | Caught by the same plus `testFuzz_SplitRedeem_NeverBeatsSingleRedeem` |
| Zero-supply check removed (either function) | Caught by `test_RevertWhen_SupplyIsZero` |
| `ceilShare` multiplies by supply instead of shares | Caught by six tests including both round-trip tests |
| `floorShare` off by one | Caught by `testFuzz_MatchesFullMath_AndBracketsExactValue`, `test_Examples` |
| `ceilShare` plus one always | Caught by `testFuzz_MatchesFullMath_AndBracketsExactValue`, `test_Examples` |
| Both directions flipped (deposit floors, redeem ceils) | Caught by both deposit-then-redeem tests and four others |

Observation: the deposit-then-redeem round-trip tests alone do **not** catch a single flipped direction (the property still holds when only one step favours the actor); they catch the combined flip. Single flips are caught by the bracket and rounding-favours-vault tests, so those tests are the load-bearing ones for T9.
The mutation harness initially matched only some failing fuzz tests (its failure regex mishandled counterexample output); the BandMath results above were re-run with the fixed harness and are unchanged.

## RewardMath (M1)
| Mutation | Result |
|---|---|
| `accrue` rounds up | Caught by `testFuzz_Accrue_IsExactFloor`, `testFuzz_Accrue_SplittingIntervalNeverPaysMore`, two unit tests |
| `accrue` wrong scale | Caught by `testFuzz_Accrue_IsExactFloor` and two unit tests |
| `eligible` ignores the commitment | Caught by `testFuzz_Eligible_IsMinimumOfThree` |
| `eligible` uses the larger depth sample | Caught by `testFuzz_Eligible_IsMinimumOfThree` |
| `accrualInterval` not capped | Caught by `testFuzz_AccrualInterval_NeverExceedsCapOrElapsed`, `test_AccrualInterval_Cases` |
| `accrualInterval` `<=` changed to `<` | **Survived: equivalent mutant.** At `now == last` the elapsed time is 0, so both forms return 0. The `==` case is redundant; left in for clarity. |
| `capToFund` returns the larger value | Caught by `test_CapToFund` |
| Curator share rounds up | Caught by `testFuzz_SplitCurator_ConservesAndRoundsTowardDepositors`, `test_SplitCurator_Examples` |
| Fee bound `>` changed to `>=` | Caught by `testFuzz_SplitCurator_ConservesAndRoundsTowardDepositors`, `test_SplitCurator_Examples` |
| Fee bound check removed | Caught by `test_RevertWhen_FeeAbove100Percent` |

First-run finding: my NatSpec and test claimed the maximum reward is below 2^228; at the extreme inputs it is about 2^228.2. The test caught it; the bound is now 2^229.
