# Ballast Deployment Guide

**Status:** Draft v0.1 · Covers local development, testnet deployment and the post-deploy checklist. Facts marked **VERIFY** must be confirmed against official sources before use. Never hardcode addresses from memory.

---

## 1. Prerequisites

- Foundry (`forge`, `cast`, `anvil`), Git, a funded deployer account on the target testnet, and an RPC URL.
- A keystore account created with `cast wallet import` (never store raw private keys in the repository or shell history).
- `config/addresses.json` populated from the official Uniswap deployments page and Unichain docs, with source links per entry. **VERIFY** chain ID, RPC and explorer.

## 2. Environment

`.env.example`:
```
RPC_URL=
CHAIN_ID=
DEPLOYER_ACCOUNT=            # name of the cast keystore account
ETHERSCAN_API_KEY=           # or the explorer's equivalent key variable
CONFIG_PROFILE=demo          # demo | prodlike
```
Load with `source .env`. Do not commit `.env`.

## 3. Configuration profiles

| Profile | Purpose | Windows |
|---|---|---|
| `prodlike` | Foundry scenario tests with time warping | hours (24 h anchor, 15 min short window, 24 h max lock) |
| `demo` | Public testnet, no time warp | minutes (for example 20 min anchor, 3 min short window, 15 min max lock) |

Both are defined as constants in `script/Config.s.sol` and mirrored in `docs/SIMULATION.md`. Demo values are for demonstrations only. They must be stated as such in the README.

## 4. Local flow (anvil or fork)

```bash
forge build --sizes
forge test
anvil --fork-url $RPC_URL &              # optional fork
forge script script/DeployBallast.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## 5. Testnet flow

1. **Mock assets (if chosen).** Deploy mock collateral and quote ERC-20s and a simple router (Q-4). Record addresses.
2. **Deploy the hook** with `DeployBallast.s.sol`:
   - Compute flags from `getHookPermissions()` using the `Hooks.*_FLAG` constants.
   - Mine a salt with `HookMiner` using the constructor arguments (PoolManager, `Config`).
   - Deploy through the CREATE2 deployer (the standard constant from `forge-std`).
   - **Assert** the deployed address's permission bits equal the intended flags.
   - Deploy `BallastLens` and `SupplyCapAdvisor`.
   - Write `deployments/<chainId>.json`.
3. **Create the pool** with `CreatePool.s.sol` (hook address, static fee, tick spacing, starting price).
4. **Seed vaults** with `SeedVaults.s.sol` (two curators with different bands and commitments).
5. **Fund standby** with `FundStandby.s.sol` (sponsor approves and funds quote currency; sets the rate within bounds).
6. **Verify** every contract (`forge verify-contract` or `verify.sh`).
7. **Create the control pool** (ordinary v4 pool, same pair and liquidity).
8. **Smoke tests** (below).

## 6. Smoke tests after deployment

| Check | Expected |
|---|---|
| External add liquidity via PositionManager | Reverts `ExternalLiquidityForbidden` |
| External remove liquidity | Reverts |
| Seed and deposit | Succeeds; shares minted |
| Swap in both directions | Succeeds; `beforeSwap` writes observation after the interval |
| `requestRedeem` and `claimRedeem` before maturity | Claim reverts `TicketNotMature` |
| `lockState()` | `CALM`, `oracleWarm` reported correctly |
| `committedDepth()` | Matches an off-chain computation from vault positions |
| Hook address flags | Equal `getHookPermissions()` |

Record transaction hashes in `deployments/<chainId>.json` and `docs/SIMULATION.md`.

## 7. Manifest format

```json
{
  "chainId": 0,
  "deployedAt": "ISO-8601",
  "commit": "git sha",
  "poolManager": "0x…",
  "hook": "0x…",
  "lens": "0x…",
  "advisor": "0x…",
  "poolId": "0x…",
  "collateral": "0x…",
  "quote": "0x…",
  "config": { "profile": "demo", "bandBps": 750, "…": "…" },
  "controlPoolId": "0x…",
  "txs": { "deployHook": "0x…", "createPool": "0x…" }
}
```

## 8. Upgrades and migration

There is no upgrade path. A fix means deploying a new hook and pool and migrating liquidity: curators create vaults on the new hook, and depositors request exits on the old one (subject to notice and lock) and deposit into the new one. Document each migration in `CHANGELOG.md`.

## 9. Operational notes

- Demo deployments use compressed windows; time-based behaviour on a public testnet cannot be fast-forwarded. Evidence for time-based behaviour comes from Foundry scenario tests (`prodlike`).
- Anyone can call `checkpoint`, `flagBreach` and `pokeStress`. The demo script should call `checkpoint` periodically to keep accrual accurate.
- Keep a record of the PoolManager's address and the version of v4 used by the target chain. **VERIFY** hook permission bit order on the target chain before mining the final address.

## 10. Release checklist

- [ ] CI green on the release commit, coverage gates met.
- [ ] Slither notes reviewed.
- [ ] `docs/` complete and consistent with code.
- [ ] Deployment manifest committed; contracts verified on the explorer.
- [ ] Smoke tests recorded.
- [ ] README results table filled from `analysis/results/` with the pre-registered bar stated.
- [ ] `SECURITY.md` contact address replaced with a real one.
