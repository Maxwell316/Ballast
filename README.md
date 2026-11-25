# Ballast

**Depth that can't leave when the liquidation arrives.**

Ballast is a Uniswap v4 hook that lets curators commit liquidity to the price band where liquidations will sell, locks that liquidity against withdrawal while the market is under stress, and publishes the committed depth on-chain so lending risk models can size collateral caps from depth that is actually guaranteed.

> Status: under development. Testnet only. Unaudited. See [SECURITY.md](SECURITY.md).

---

## Why

Lending risk teams size collateral supply caps from DEX depth. The public methodology discussed on Aave governance sets caps at roughly twice the liquidity available at the liquidation-penalty price impact, yet that liquidity is uncommitted: LPs can leave at any time, and incentives that attract it can end. Thin depth turns liquidations into slippage and bad debt. Ballast makes a pool's depth **committed, enforced by the pool, and measurable on-chain**.

## How it works (short)

1. **Hook-owned liquidity.** Only the hook can add or remove liquidity in a Ballast pool, so the pool's entire depth is committed depth.
2. **Curator vaults.** Curators choose ranges and a depth commitment. Depositors hold proportional, in-kind vault shares (no price oracle in share accounting).
3. **Notice and stress lock.** Exits go through a notice queue. When the pool's short-term TWAP falls sharply versus its own anchor TWAP, the queue freezes until calm or a hard maximum lock elapses. The lock cannot re-arm until the market has been calm.
4. **Standby fee.** A sponsor funds a per-second standby fee paid to vaults on verified, conservatively sampled committed depth.
5. **Depth views.** `committedDepth`, `liveDepth(impactBps, horizon)` and `lockState` let risk consumers read guaranteed depth, net of exits maturing inside their horizon. **Lenders should size caps from `liveDepth`.** `committedDepth` is anchor-based and exists for coverage and reward accounting.

Ballast does **not** protect depositors from price losses. The lock holds risk in place on purpose, and depositors are paid a standby fee for bearing it.

## Repository map

| Path | Contents |
|---|---|
| `src/` | `BallastHook`, `BallastLens`, `SupplyCapAdvisor`, libraries, interfaces |
| `test/` | unit, fuzz, differential, invariant, scenario, fork and gas tests |
| `script/` | deployment, pool creation, seeding, standby funding, crash replay |
| `docs/` | spec, contract reference, architecture, math, threat model, testing, economics, deployment, simulation, decisions |
| `analysis/` | simulation preregistration, tooling, results |
| `deployments/` | deployed addresses per chain |

Start with: [docs/SPEC.md](docs/SPEC.md) → [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) → [docs/CONTRACTS.md](docs/CONTRACTS.md).

## Quickstart

```bash
git clone <repo> && cd ballast
forge install
forge build --sizes
forge test
```
Deployment instructions: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Deployments

| Network | Hook | Lens | Pool | Explorer |
|---|---|---|---|---|
| _pending_ | _pending_ | _pending_ | _pending_ | _pending_ |

Demo deployments use compressed time windows for demonstration. They are not recommended production parameters.

## Results

Simulation results versus an ordinary pool are generated from `analysis/results/` under a pre-registered protocol ([docs/SIMULATION.md](docs/SIMULATION.md)). _Pending._

## Known limitations

Standard ERC-20 tokens only; a cold or sparse pool has no stress protection; sustained manipulation in a shallow pool can trigger or delay a lock; depth is counted equally anywhere in the band; standby sampling is conservative at interval endpoints only; holders with already matured exit tickets can leave before the lock engages at crash onset; sponsor funds are not withdrawable in v1. Full list: [SECURITY.md](SECURITY.md) and [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

## License

MIT. See [LICENSE](LICENSE).
