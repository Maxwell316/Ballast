# Ballast Economics

**Status:** Draft v0.1 · This document explains who pays, who earns, why each party might participate, and how the standby fee should be priced. It contains **no performance numbers**. Any figure that appears here must come from the pricing and simulation work described in §9 and be labelled with its data source and date.

---

## 1. The market Ballast addresses

Lending risk frameworks size collateral supply caps from DEX depth. The public Chaos Labs methodology discussed on Aave governance sets the cap at about twice the liquidity available at the asset's liquidation-penalty price impact. Governance threads for several assets show that this depth can be thin, and they note that liquidity may fall once incentives end. Issuers fund liquidity programs, but the liquidity they pay for is free to leave.

Ballast creates a product that can be bought: **depth in the liquidation band that cannot leave quickly, and cannot leave at all during stress (up to a bound), measurable on-chain.** The buyer is whoever benefits from a higher or safer cap: collateral issuers and lending protocols' risk teams.

Sources (paraphrased in this repository; consult them directly):
- https://governance.aave.com/t/arfc-onboard-usde-to-aave-v3-on-ethereum/17690
- https://governance.aave.com/t/arfc-onboard-lseth-to-aave-v3-core-instance/22957/3
- https://governance.aave.com/t/direct-to-aip-weeth-e-mode-risk-parameter-adjustment-on-aave-v3-plasma-instance/23381
- https://governance.aave.com/t/arfc-prime-instance-wsteth-borrow-rate-rseth-supply-cap-update/20644
- https://governance.aave.com/t/arfc-deploy-aave-v3-on-mantle/20542/14

## 2. Parties and incentives

| Party | Gives | Gets | Why participate | Main risk |
|---|---|---|---|---|
| **Sponsor** (issuer, risk DAO) | Standby fee in the quote currency | Verifiable committed depth, a basis for higher or safer caps | Replaces emissions that buy uncommitted liquidity | Underpricing yields no depth |
| **Curator** | Management of ranges and coverage | Capped share of fees and standby rewards, a visible record | Professional fee income | Reputation and breach record |
| **Depositor** | Capital, accepts notice and lock | Trading fees plus standby share | Yield for bearing tail exposure | Price loss, bounded trap |
| **Trader / liquidator** | Nothing extra | Depth present when it matters | Better execution in stress | None added by Ballast |
| **Lender / risk team** | Reads views | A measurable depth input | Better cap sizing | Misreading views (see THREAT_MODEL T17) |

## 3. Tail liquidity is short a put

Liquidity placed below spot (in the liquidation direction) is a standing bid for collateral. If price falls through the band, the position converts quote into collateral at progressively worse prices. In option terms the committed depth is short a strip of puts struck across the band, and the stress lock extends the exposure by preventing exit while the market keeps falling.

Rough loss accounting for a vault committing depth `D` (in collateral units) over a band of relative width `X` from the anchor price `P`, ignoring fees:
- If price falls to the far edge, the position holds about `D` collateral bought at an average price of about `P(1 − X/2)`, against a spot of `P(1 − X)`, so the mark-to-market loss is about `D · P · X / 2`.
- If price keeps falling while the lock holds, the position bears the full move on `D` collateral beyond the edge.
- If price recovers, the position sells back through the band and the loss is recovered (and it earns fees along the way).

**Implication:** the fair standby payment is the **option premium** for this exposure plus the cost of capital for the lock. It rises with volatility, with band width and with lock length.

## 4. Pricing the standby fee

Let `r` be the standby rate per unit of depth per unit time (in value terms), `T` an accounting horizon, `π` the probability that price reaches the band within `T`, `ℓ` the expected loss given conversion (including drift during the lock), `c` the depositor's cost of capital on the committed value, and `φ` expected fee income. A necessary condition for participation:
```
r · T  ≥  π · ℓ  +  c · V · T  −  φ     (per unit of committed value V)
```
Notes:
- `π` and `ℓ` depend on volatility; use implied volatility or a conservative realized-volatility estimate for the asset and horizon.
- `ℓ` must include lock extension: use the distribution of drawdowns **after** touching the band over `maxStressLock`.
- `φ` is small for far-from-spot liquidity and larger in turbulent conditions.
- Hedged participants (for example market makers who offset conversion exposure in perpetuals or centralized venues) can accept a lower premium, because their `ℓ` is net of the hedge cost.

Parameter implications:
- Set `bandBps` to the liquidation penalty or the impact threshold the risk framework uses. A wider band costs more per unit of depth.
- A shorter `maxStressLock` and a longer `exitNotice` trade off consumer guarantees against participant cost. Document both.
- `stressEnterBps` should sit well inside `bandBps` so the lock engages before conversion is deep.

**Conversion to the on-chain rate.** The contract rate is quote raw units per collateral raw unit per second scaled by `RATE_SCALE`. Convert from a value-based rate using the collateral price in quote at funding time and both tokens' decimals. The sponsor re-sets the rate within `maxStandbyRate` as prices move. Provide a calculator script in `analysis/` and document its assumptions.

## 5. The sponsor's side

A sponsor should compare the annualized standby cost against the value of the cap or risk reduction it buys:
```
benefit  ≈  value(Δ cap)  or  value(reduction in expected bad debt and liquidation shortfall)
Δ cap    ≈  m · Δ liveDepth(i, h)                 (m is the framework multiplier; the Chaos method uses 2)
```
We do not assert that Ballast is cheaper than emissions. It buys a different thing: committed, bounded-exit depth in the specific band that matters. Whether that is worth the price is a sponsor decision.

## 6. Curators

- Earn `curatorFeeBps` (capped) on crystallized trading fees and standby rewards, never on principal.
- Face a visible on-chain record: covered seconds over tracked seconds, number of re-ranges, breaches, and stress episodes during which commitments stayed in place.
- Cannot withdraw funds. Their main cost is attention: keeping coverage as the anchor drifts.
- Competition: depositors can switch curators by queueing an exit and depositing elsewhere, which pressures fees and service quality.

## 7. Depositors

Expected yield = trading fees + standby share − expected tail loss − opportunity cost of the lock. Typical participants who may find this attractive:
- Yield seekers who understand put-selling economics.
- Issuers placing their own treasury liquidity (they benefit from the cap they unlock).
- Hedged market makers.

## 8. Failure and edge economics

| Situation | Outcome |
|---|---|
| Standby too low | Little depth is committed; views show low depth. No worse than the status quo. |
| Standby funding stops | Accrual ends; exits proceed under notice; views decay honestly. |
| Extreme crash beyond the band | Committed LPs hold collateral exposure during the lock. This is the product working as designed, not a bug. |
| Curator neglects coverage | Breach after grace; accrual stops; record shows it. |
| One dominant curator | Depth concentration risk; mitigated by `MAX_VAULTS` and visibility through views. |

## 9. Required modelling work (to be done, not assumed)

1. **Pricing notebook** (`analysis/pricing/`): estimate `π` and `ℓ` from historical price data for chosen assets, including post-touch drawdown over the lock horizon. Report data source, date range and method.
2. **Rate calculator:** value-based to on-chain rate conversion with decimals and price inputs.
3. **Sensitivity tables:** rate vs `bandBps`, `maxStressLock`, volatility.
4. **Depth vs cost curve:** committed depth purchasable for a given budget under stated assumptions.

Until these exist, `ECONOMICS.md` is a framework, not evidence.

## 10. What this document does not claim

- It does not claim Ballast reduces bad debt in practice.
- It does not claim a specific standby rate is sufficient.
- It does not claim depositors are protected from price losses.
- It does not claim any lending protocol has adopted or will adopt the depth views.
