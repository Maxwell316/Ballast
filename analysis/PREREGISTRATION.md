# Pre-registration: Scenario S1 (Crash)

**Committed before any simulation code exists.** Do not edit the scenario or the bar after results are seen. A mistake found later is handled by a dated amendment at the bottom, with the original results kept visible. Everything is reported unchanged, including a missed bar.

## Setup
- Profile: `prodlike` (`ConfigFixture.prodLike`, CLAUDE.md §6.10 defaults), time warped in Foundry.
- Two pools with the same pair, fee tier, tick spacing and **identical liquidity layout**: a Ballast pool (two curator vaults) and a plain v4 control pool (no hook).
- Assets: mock collateral and quote ERC-20s, both 18 decimals (assumption).
- Layout: both pools hold the same positions. The total liquidity is sized so that committed depth inside the band at the initial anchor is exactly `D0 = 1,000,000` collateral units. The layout (ranges and liquidities) is fixed by the scenario code before the run and recorded in the results JSON; it is not tuned afterwards.
- Warm-up: 24 h at constant price `P0` so the anchor window is fully covered in the Ballast pool.

## Price path
Fixed vector: `analysis/vectors/s1_path.json` (price in bps of `P0`, one entry per minute). After warm-up the price falls linearly by 12% over 120 minutes. A single market-driver account executes swaps to reach each minute's target price, identically in both pools, by the same router.

## LP behaviour model (assumption, not a prediction)
- **Control pool:** 50% of liquidity (by value) is withdrawn at the first evaluation where short-TWAP deviation in the liquidation direction exceeds `stressEnterBps`. Evaluation uses the same TWAP definitions and cadence (`observationInterval`) as the Ballast pool.
- **Ballast pool:** the same holders request redemption at that same moment.
- **Exit race (T18):** an additional 10% of Ballast shares hold redeem tickets that matured before crash onset. Their holders claim at crash onset, as early as the machine allows (worst case for Ballast).

## Liquidation-sized sell
40% of `D0` (400,000 collateral units) sold into the pool in a single swap, at minute 60 of the crash, in both pools by the same router.

## Metrics
1. Price impact of the sell, in bps (final price versus pre-sell price).
2. Fraction of the sell filled before the far band edge.
3. Exit attempts blocked versus executed (per pool).
4. Lock violations (liquidity leaving while the lock is active, Ballast only).
5. Swap reverts.
6. Final LP token holdings (collateral and quote), reported, not spun.

## Pass/fail bar
1. **Safety (hard):** zero lock violations, zero exits executed while the lock is active, zero swap reverts, all invariants pass.
2. **Behaviour:** state transitions match both stress references (table-driven vectors and the pure `StressMachine`) on all scenarios.
3. **Execution:** Ballast price impact on the liquidation sell is at least **25% lower** than the control's under the stated LP behaviour model. If the exit-race tickets cause the result to miss the bar, it is reported unchanged.

## Threats to validity (to be repeated in `docs/SIMULATION.md`)
Results depend on the assumed LP behaviour. They show what happens if LPs flee, not that they would. One path, one layout, one pair of mock assets; no extrapolation to mainnet. The lock traps price risk by design; final LP holdings are reported without claiming protection.
