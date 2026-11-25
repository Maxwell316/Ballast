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

## DepthMath (M1)
Tests: `test/unit/libraries/DepthMath.t.sol` (unit and properties, all six decimals/ordering scenarios, both directions) and `test/fuzz/DifferentialDepthMath.t.sol` (real PoolManager, swap to a far-edge `sqrtPriceLimit`, LP fee 0 / 0.3% / 1%, protocol fee 0 / 400 / 1000 pips in the liquidation direction with a different value in the other direction, net of both fees).

| Mutation | Result |
|---|---|
| `absorbable` rounds up (token0) / (token1) | Caught by both differential tests and two unit tests each |
| Overlap lower bound `max` → `min` (token0) | Caught by seven tests including the off-chain worked examples |
| Overlap upper bound `min` → `max` (token0) | Caught by both differential tests and four unit tests |
| Overlap lower bound `max` → `min` (token1) | Caught by both differential tests and three unit tests |
| Overlap upper bound `min` → `max` (token1) | Caught by both differential tests and four unit tests |
| Live depth: spot cap removed (token0) / spot floor removed (token1) | Caught by both live differential tests and the live-equals-anchor test |
| Live depth: lower/upper bound `max`/`min` flipped | Caught by both live differential tests and the live-equals-anchor test |
| Fee: directional protocol-fee halves swapped | Caught by both differential tests and `test_EffectiveSwapFee_MatchesV4Formula` |
| Fee: protocol fee ignored | Caught by `test_EffectiveSwapFee_MatchesV4Formula` |
| `grossUp` rounds down | Caught by `testFuzz_GrossUp_IsUpperBoundOfInverse` |
| `grossUp` 100%-fee bound `>=` → `>` | Caught by `test_RevertWhen_SwapFeeIs100Percent` |

**Equivalent mutants (survived, by construction):** the `hi <= lo` → `<` and `sqrtHi <= sqrtLo` → `<` comparisons (equal bounds give a zero amount either way) and removing the `liquidity == 0` guard (zero liquidity gives a zero amount). These guards only save gas. Two orientation guards (`farTick >= nearTick`, `nearTick >= farTick`) were found to be **fully redundant** (an inverted band always yields `hi < lo`) and were removed from `absorbable`, along with the mutants that targeted them.

**Measured rounding bound (differential):** in the 216-case grid (3 positions each) the measured net input exceeded `DepthMath` by 1 to 5 wei and never fell below it. The test bound is `4·(positions + 1) + 4` wei.

## Observations (M1)
Tests: `test/unit/libraries/Observations.t.sol`, `test/fuzz/ObservationsDifferential.t.sol` (naive full-history model, adversarial swap patterns including same-timestamp swaps, many swaps inside one snapshot interval and extreme ticks), `test/gas/ObservationsGas.t.sol`.

| Mutation | Result |
|---|---|
| Accumulator rate-limited like a snapshot (the flaw ADR-013 fixed) | Caught by two differential fuzz tests and four unit tests |
| Same-timestamp guard removed | Caught by `test_Update_SameTimestampIsNoOp` |
| Snapshot boundary `>=` → `>` | Caught by `test_Update_SnapshotBoundary_IsInclusive` and four others (a first run **survived** until that boundary test was added) |
| Tick sign flipped in the accumulator | Caught by ten tests |
| Ring overwrite index not advanced | Caught by `test_RingWrapsAndKeepsOrder`, `test_Warm_RegressesBelowMinimumCardinality_ButNotAtMinimum` |
| Ring fills one entry too many (`<` → `<=`) | Caught by `test_RingWrapsAndKeepsOrder` |
| Oldest-index offset wrong in `_physical` | Caught by three tests including the warm-monotonic fuzz |
| Cold check `<` → `<=` | Caught by `testFuzz_CumulativeAt_WithinDocumentedBound`, `test_RingWrapsAndKeepsOrder`, one more |
| Binary search upper bound off | Caught by eight tests |
| Binary search `<=` → `<` | **Survived: equivalent mutant.** Picking the earlier element when a snapshot timestamp equals the target interpolates to exactly that snapshot's cumulative, so the result is identical; the `a.timestamp == target` shortcut is an optimization. |
| Interpolation rounds toward zero / wrong denominator | Caught by `test_TwapTick_RoundsTowardNegativeInfinity` / three tests |
| Newest-snapshot bracket uses the snapshot instead of the accumulator | Caught by `testFuzz_CumulativeAt_WithinDocumentedBound` |
| TWAP cold branch divides by the window | Caught by `test_ColdHistory_UsesActualElapsedTime` |
| `isWarm` boundary `<=` → `<` | Caught by four tests |
| Current tick ignored when extending | Caught by eight tests |
| Time-regression check removed in `update` | Caught by `test_RevertWhen_TimeRegresses` |
| Floor division replaced by truncation in the warm TWAP | Caught by `test_TwapTick_RoundsTowardNegativeInfinity` |
| Double-initialization guard removed | Caught by `test_RevertWhen_InitializedTwiceOrWithZeroCardinality` |
| `lastTick` not recorded | Caught by `test_Update_RecordsPreSwapTickAndTimestamp` (a first run lacked that test) |
