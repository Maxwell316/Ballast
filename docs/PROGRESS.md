# Progress

**Read with `CLAUDE.md`. A fresh session can resume from these two files alone.**

## Current milestone
M3 (vault core) in progress. The split-custody work is complete (ADR-045, ADR-050..054) and merged to `main`; M3 tests, then M4..M11, continue in continuous mode.

## Done
- M0-M2 (scaffold, maths libraries, hook skeleton) and the S1 pre-registration (`analysis/PREREGISTRATION.md`, commit f3d4a05; never edit).
- Split custody: `BallastHook` (callbacks, oracle, stress, gate, `enterVaultOp`, `evaluateStress`), `BallastVaults` (all vault operations, positions, claims, `extsload`), `BallastShares` (ERC-6909 shares), `BallastStandby` (fund, rate, accrual), `BallastDepth` (stateless depth maths), `BallastLens` (decoded views, depth, previews), `SupplyCapAdvisor`.
- Deployment (ADR-050): vaults deployed first at a nonce-predicted address, hook mined over the full creation code and CREATE2-deployed, binding checked in the hook's constructor and by `script/VerifyBinding.s.sol`. `DeployBallast` runs end to end on a fork of chain 1301 (`test/fork/DeployBallastScript.t.sol`).
- Tests: M2 suite adapted and green; `LiquidityGate` (G-1 local, T19), `HookOnlyLiquidityFork` (real PositionManager and routers on the 1301 fork), `LensLayout`, `Sizes`, `BallastDepthDifferential`. Gate mutations (`!=`, check removed) caught (MUTATION_LOG.md).
- Sizes (`via_ir`, `optimizer_runs = 200`): hook 14,027 runtime / 18,117 initcode; vaults 24,268 / 36,194 (margin 308 to EIP-170, inside the ADR-051 band); standby 3,105; shares 2,022; depth 2,889. Enforced by `test/unit/Sizes.t.sol`.

## Known gaps in the vault surface (to close in M3-M7)
- `flagBreach` was removed (ADR-052): breach is recorded at the first checkpoint after the grace period.
- Vaults runtime has 308 bytes of headroom to EIP-170; further growth in the vaults needs the ADR-051 fallback cuts (b: `setCommitment`, c: `deployIdle`, d: `cancelRedeem`), asked in that order.
- Gas budgets in `docs/TESTING.md` have not been re-measured for the split (do with the M3 gas tests).

## Next
1. M3 tests: lifecycle unit tests (seed/deposit/redeem/cancel/claim), proportional-share fuzz, rounding round-trip (INV-5), donation, rerange dust bound, alias check, shares ledger (INV-4), invariants INV-1..5.
2. M4 coverage and breach flow, then M5 stress gate and exit queue; report at the end of M5.
3. Continue M6..M11.

## Resume commands
```
git checkout main && forge build --sizes && forge test --no-match-path "test/fork/*"
RPC_URL=https://sepolia.unichain.org forge test --match-path "test/fork/*"    # public Unichain Sepolia RPC from config/addresses.json
```
