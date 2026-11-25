# Ballast Mathematics

**Status:** Draft v0.2 · Companion to [SPEC](SPEC.md). Every formula that appears in code must appear here with its rounding direction and a justification. Numerical examples are illustrative; implementers must recompute them in tests.

---

## 1. Conventions

- Uniswap price `P = 1.0001^tick` is **token1 per token0**. `sqrtPriceX96 = sqrt(P) · 2^96`.
- Let `c0 = collateralIsCurrency0`. Liquidations sell collateral into the pool and push price in the **liquidation direction**: ticks decrease if `c0`, increase otherwise. Define `σ = c0 ? −1 : +1` (the sign of tick movement in the liquidation direction).
- Rounding is chosen to **understate depth** and **overcharge entrants / underpay leavers**. Each function states its direction.

## 2. Basis points to ticks

For a fractional price fall `x = bps / 10_000` of the collateral's value in quote terms:

- If `c0`: the price `P` falls to `P(1 − x)`.
- If not `c0`: the collateral's quote-denominated value is `1/P`, so `P` rises to `P / (1 − x)`.

In both cases the tick distance is
```
Δ(x) = ln(1 / (1 − x)) / ln(1.0001)
```
Illustration: `x = 7.5%` gives `Δ ≈ 779.6` ticks (the real implementation must compute this on-chain and test against a high-precision reference).

- **`bpsToTicksDown(bps)`:** conservative floor of `Δ(x)`, defined precisely below. Used for the band: a narrower band means less depth, which is conservative.

**Epsilon rule (ADR-035).** Let `Δ_ref(bps)` be the exact value (computed off-chain with 60-digit decimal arithmetic and committed as `test/data/band_ticks_ref.json`, with `Δ_ref` in WAD). On-chain, `Δ_raw = lnWad(1e18 · 10000 / (10000 − bps)) · 1e18 / LN_1_0001_WAD` and
```
Δ_wad = Δ_raw − EPS_WAD            // EPS_WAD = 1e9, i.e. 1e-9 ticks
bpsToTicksDown = floor(Δ_wad / 1e18)
```
`EPS_WAD` must exceed the worst-case fixed-point error of `Δ_raw` so that `Δ_wad ≤ Δ_ref` always holds. The contractual postcondition for every `bps` in `[1, 2500]` is `floor(Δ_ref) − 1 ≤ result ≤ floor(Δ_ref)`. The test checks this against the committed table for all 2,500 values, checks `Δ_wad ≤ Δ_ref` in WAD, and a mutation run with `EPS_WAD = 0` must break at least one check.
- **`bpsToTicksNearest(bps)`:** `round(Δ(x))`. Used for stress thresholds, where bias in either direction is a policy choice and nearest is neutral.
- On-chain: compute `ln` with a fixed-point library (for example solady `lnWad`), then divide by the constant `ln(1.0001)` in WAD. Validate in tests over the full bps range against a reference implementation, with a maximum permitted error of 1 tick.

## 3. Absorbable collateral

For a position with liquidity `L` over `[√Pl, √Ph]` (square-root prices, `Pl < Ph`):

- **Collateral = token0 (`c0`).** Price falls from `Ph` to `Pl` when token0 is sold into the pool. Token0 absorbed:
  ```
  Δx = L · (1/√Pl − 1/√Ph)         // = SqrtPriceMath.getAmount0Delta(√Pl, √Ph, L, roundUp=false)
  ```
- **Collateral = token1.** Price rises from `Pl` to `Ph` when token1 is sold into the pool. Token1 absorbed:
  ```
  Δy = L · (√Ph − √Pl)             // = SqrtPriceMath.getAmount1Delta(√Pl, √Ph, L, roundUp=false)
  ```

These are amounts net of swap fees. We report net amounts to consumers (conservative) and expose a helper for gross-up that uses the **effective swap fee** (ADR-031).

**Effective swap fee (verified in `lib/v4-core/src/libraries/ProtocolFeeLibrary.sol:38-46` and `Pool.sol:286-307`).** Fees are in pips (1e-6). The pool's `slot0` holds `lpFee` and a 24-bit `protocolFee` packed as two 12-bit directional halves: `zeroForOne` uses the low 12 bits, `oneForZero` the high 12 bits (`getZeroForOneFee`, `getOneForZeroFee`). Each half is at most `MAX_PROTOCOL_FEE = 1000` pips (0.1%). For a swap with directional protocol fee `p` and LP fee `l`, v4 uses
```
swapFee = p + l − floor(p · l / 1_000_000)        // = 1 − (1−p)(1−l) up to the floor; protocol fee comes off the input first
```
(when `p == 0` it is just `l`). The liquidation direction is `zeroForOne` iff the collateral is currency0, so the helper selects the directional half accordingly. Gross input to push `net` collateral through the band:
```
gross = ceil( net · 1_000_000 / (1_000_000 − swapFee) )        // rounded up: an upper bound on what a seller must pay
```
`slot0.lpFee` and `protocolFee` are read from the PoolManager (`StateLibrary.getSlot0`), never assumed from config, because the PoolManager's owner can change the protocol fee (SECURITY, THREAT_MODEL). The depth numbers published by the lens stay **net of fees**; only the optional gross-up helper uses the effective fee.

**Band overlap.** With anchor tick `A` and band length `B = bpsToTicksDown(bandBps)`:

| | Band (in ticks) | Overlap with position `[tl, tu]` |
|---|---|---|
| `c0` | `[A − B, A]` | `[max(tl, A − B), min(tu, A)]` |
| not `c0` | `[A, A + B]` | `[max(tl, A), min(tu, A + B)]` |

If the overlap is empty or has zero width, the contribution is zero. Otherwise convert the overlap ticks to `√P` with `TickMath.getSqrtPriceAtTick` and apply the formula above with the position's liquidity. Sum over positions. All rounding is **down**.

### 3.1 Committed depth for a vault
```
D_v = Σ_i absorbable(position_i ∩ band)
```
It depends only on ranges, liquidity and the anchor, not on spot. Pool committed depth sums `min(D_v, K_v)` over non-breached vaults.

### 3.2 Live depth
Let `t_s` be the current tick and `√P_s` the current sqrt price. For an impact of `i` bps, `B_i = bpsToTicksDown(i)`. The near edge is the exact current price, the far edge `farTick = t_s + σ·B_i`:

- `c0`: for each position, `√Pl = sqrt(max(tl, farTick))`, `√Ph = min(√P_s, sqrt(tu))`. Contribution is zero if `√Ph ≤ √Pl`.
- not `c0`: `√Pl = max(√P_s, sqrt(tl))`, `√Ph = sqrt(min(tu, farTick))`.

Positions entirely behind the current price (already converted) contribute zero. Positions straddling the price contribute only the part between spot and the far edge.

**Implementation (ADR-023).** Because of G-1 every unit of pool liquidity belongs to some vault position, so pool-wide figures are sums over `MAX_VAULTS × MAX_POSITIONS` positions. No tick scan is performed.

### 3.3 Netting maturing exits
For vault `v` and horizon `h`, let `E_v(h)` be shares in tickets whose effective exit time `max(maturity, lockedUntil) ≤ now + h` and `S_v` total shares (including escrow and burned minimum). Then
```
liveDepth_v(h) = floor( liveDepth_v · (S_v − E_v(h)) / S_v )
```
Because `lockedUntil` is included in the effective exit time, a ticket that matures during an active lock is not counted as leaving before the lock ends.

## 4. TWAP

Observation: `(t_k, C_k)` with `C_k = Σ tick_j · Δt_j`. Between swaps the tick is constant, so `C` is exact.

- **Running accumulator (ADR-013).** State `(t_s, τ_s, C)`: time of the last accumulator update, the pre-swap tick read then, and the cumulative at `t_s`. At the start of every `beforeSwap` with `now ≠ t_s`, with `τ` the pre-swap `slot0.tick`: `C ← C + τ · (now − t_s)`, `t_s ← now`, `τ_s ← τ`. The accumulator is never skipped, so `C` is exact at every update time.
- **Snapshots.** At most once per `observationInterval`, `(now, C)` is appended to the ring buffer. Every snapshot value is exact.
- **Exact current value.** `C(now) = C + τ_now · (now − t_s)` with `τ_now` the PoolManager's current tick. This is exact because the tick has not changed since the last swap.
- **Query at `t* < now`.** If `t*` is a snapshot time the value is exact. Otherwise linearly interpolate between the bracketing snapshots `(t_a, C_a)` and `(t_b, C_b)`. For `t* ≥` the newest snapshot the bracket is `(t_snap, C_snap)` and `(t_s, C)` when `t_s > t_snap`, else the exact extension above.
- **TWAP over window `W`:** `(C(now) − C(now − W)) / W`, rounded toward negative infinity (if the difference is negative and not divisible, subtract one).
- **Warmth.** `warm_W` holds iff the oldest retained snapshot has timestamp `≤ now − W`. The stress machine requires `warm_anchorWindow`, which implies the short window is covered. Otherwise the oldest snapshot is used and `warm = false`; the TWAP is then `(C(now) − C_oldest) / (now − t_oldest)` (R-ORC-6), or the current tick if `now == t_oldest`.
- **Warm is monotonic (R-ORC-7, ADR-034).** Snapshot times are strictly increasing with gaps `≥ I`. Cardinality `N ≥ ceil(W/I) + 1`. After the ring is full, the oldest retained snapshot is the `N`-th newest, with timestamp `≤ t_newest − (N−1)·I ≤ t_newest − W ≤ now − W`. Before the ring is full nothing is overwritten, so the oldest snapshot is the first one and `now − W` only grows. Hence `warm` can only go from false to true.

**Interpolation error bound.** Interpolation is exact whenever no swap occurred between the two bracketing snapshots, because the tick is then constant and `C` is linear. Snapshots are written at swap times with spacing at least `I = observationInterval`. Any swap that fell between two consecutive snapshots `t_a < t_b` must lie in `[t_a, t_a + I)`: a later swap would itself have satisfied the spacing rule and been snapshotted, and a swap at or after `t_a + I` is `t_b`. On `[t_a + I, t_b]` the tick is constant, so the non-linear part is confined to an interval of length less than `I`. Let `Δτ` be the maximum tick swing during that interval. Then `|C_interp(t*) − C(t*)| ≤ I · Δτ`, and since only the window-start term is interpolated (the end term is exact):
```
|TWAP_computed − TWAP_true| ≤ I · Δτ_max / W        (before the floor rounding of 1 tick)
```
Example (illustrative, not measured): `I = 60 s`, `W = 900 s`, `Δτ_max = 300` ticks gives at most 20 ticks. The bound shrinks with longer windows and shorter intervals; `Observations` tests MUST confirm it against a full-history reference model with adversarial swap patterns inside one interval.

Why pre-swap tick: the tick in effect during `[t_s, now]` is the one left by the previous swap, which is what `slot0` shows at the start of the next swap. Updating once per timestamp means a swap and its reversal in one block carry zero weight.

## 5. Stress deviation
```
dev = c0 ? (A − S) : (S − A)     // ticks; positive means the short TWAP is displaced in the liquidation direction
enterTicks = bpsToTicksNearest(stressEnterBps)
exitTicks  = bpsToTicksNearest(stressExitBps)
```
Hysteresis requires `exitTicks < enterTicks`; the constructor rejects configurations where rounding makes them equal.

## 6. Proportional shares

Let `S` be total share supply (including escrow and the burned minimum), `s` the shares requested.

- **Deposit.** For each position `ΔL_i = ceilDiv(L_i · s, S)`; for each currency `a_j = ceilDiv(idle_j · s, S)`. The PoolManager then rounds the amount owed for `ΔL_i` up as well. Total owed ≥ the exact proportional value.
- **Redeem.** For each position `δL_i = floorDiv(L_i · s, S)`; idle slice `floorDiv(idle_j · s, S)`. The PoolManager rounds amounts received down.
- **Round trip (INV-5).** Deposit then immediate redeem of the same shares returns at most what was paid, since each step rounds against the actor. Equality can only hold when all divisions are exact.
- **Supply floor.** `S ≥ MINIMUM_SHARES` always, so divisions never divide by zero. Because the shares are requested rather than derived from deposited amounts, donations cannot change the cost of a share; accounting uses internal ledgers, never `balanceOf`.
- **Fee neutrality.** Because crystallization precedes every share change, accrued fees are already in `idle` (after the curator cut) when slices are computed, so entrants pay for them in kind and leavers receive them in kind.

## 7. Standby reward

```
interval  = min(now − lastCheckpoint, maxAccrualInterval)
eligible  = min(depthStart, depthNow, K_v)               // conservative at the interval's endpoints
reward    = floor( mulDiv(eligible · interval, rate, RATE_SCALE) )   // 512-bit intermediate
reward    = min(reward, fundBalance)
```
**Depth sample (amended, ADR-025).** The sample at a checkpoint is
```
d = min( D_v , Λ_v )
D_v = anchor-based committed depth of vault v (§3.1)
Λ_v = the vault's live absorbable collateral measured from current spot over bandBps of price impact (§3.2 applied to this vault, no exit netting)
eligible = min(d_start, d_now, K_v)
```
This holds in every state, including STRESS and RECOVERING, so standby pays only for depth that is still available: once a crash has consumed the vault's liquidity, `Λ_v` falls and so does the reward. Λ_v uses the same rounding-down rules as §3.2.
- `eligible · interval < 2^128 · 2^32 = 2^160`; multiplied by `rate < 2^128` this exceeds 2^256, so use `FullMath.mulDiv`.
- Units: `rate` is quote-token raw units per collateral-token raw unit per second, scaled by `RATE_SCALE`. Document decimals in `ECONOMICS.md`.
- **Limit of the sampling argument.** Taking the minimum of the interval's endpoints does not bound the depth path in between if the anchor drifts non-monotonically. The error is bounded by `maxAccrualInterval × rate × (max variation of D_v over the interval)`. Mitigations: small `maxAccrualInterval`, permissionless `checkpoint`, and re-range accrual using `min(before, after)`.

## 8. Credit split
```
toCurator = floor(reward · curatorFeeBps / 10_000)
toIdle    = reward − toCurator
```
The same split applies to crystallized trading fees per currency. Rounding favours depositors by at most one unit.

## 9. Differential and property targets

| Property | Reference | Tolerance |
|---|---|---|
| `DepthMath` ≤ brute-force swap | Real PoolManager swap of increasing size until price reaches the far edge, measuring input net of fee | Never overstates; understatement bounded by rounding (document the bound) |
| `bpsToTicks*` | High-precision off-chain log | ≤ 1 tick; direction as specified |
| `Observations.twapTick` | Naive full-history model | Exact up to rounding rule |
| `StressMachine.next` | Table-driven model | Exact |
| `VaultMath` round trip | Exact rational arithmetic | Never in actor's favour |
| `RewardMath.accrue` | 512-bit rational reference | Exact floor |

## 10. Worked example (to be recomputed in tests)

Collateral is token0. Anchor tick `A = 0`, band `B = 779`, one position `[-1200, 0]` with liquidity `L`. Overlap is `[-779, 0]`. Absorbable collateral:
```
L · (1/√P(-779) − 1/√P(0)) = L · (1.0001^(779/2) − 1)  ≈ L · 0.0397
```
So the band absorbs roughly `0.0397 · L` units of token0 (illustrative, since `1.0001^389.5 ≈ 1.0397`). Tests must replace this with exact integer results from `TickMath`.
