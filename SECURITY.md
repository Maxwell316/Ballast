# Security Policy

Ballast custodies liquidity. Treat it as unaudited software unless an audit report is linked here.

## Status
- **Audits:** none yet.
- **Deployments:** testnet only (see `deployments/`). Do not deposit funds you cannot afford to lose.

## Trust model (summary)
- A deployment is valid only if `script/VerifyBinding.s.sol` passes against it (it checks that the hook and the vaults are bound to each other in both directions, with matching configuration and flags).
- No owner, no pause, no upgrade. Funds move only under the rules in `docs/SPEC.md`.
- The sponsor can fund and set a bounded standby rate. It cannot touch depositor funds.
- Curators manage ranges and earn a capped fee. They cannot withdraw depositor funds.
- Depositors accept an **exit notice** and a **bounded stress lock**. The lock traps price risk by design; Ballast does not protect against price losses.

## Known limitations
- Dependency-level trust assumption: the PoolManager's owner can set the protocol fee (up to 0.1% per direction in the pinned v4-core). This is not a Ballast privilege and cannot touch custody, but it changes swap costs, so the gross-up helper reads the effective fee from the pool. On Unichain Sepolia the PoolManager owner is an address outside Ballast's control (docs/VERIFICATION.md F-10).
- Supported tokens: standard ERC-20 only. Fee-on-transfer, rebasing, blocklist and callback tokens are unsupported.
- Tokens sent to the hook outside the documented functions are not accounted for and cannot be recovered.
- A cold or very sparse pool has no stress protection until its oracle is warm.
- A well-capitalized attacker can trigger or delay a lock in a shallow pool (see `docs/THREAT_MODEL.md`, T3, T4 and T18).
- Depth is counted equally anywhere in the band (T5).
- OpenZeppelin `uniswap-hooks` v1.2.1 (`BaseHook`, `CurrencySettler`) is **not itself audited**. According to OpenZeppelin's published pages, earlier release candidates (v1.0.0 RC 1, v1.1.0 RC 1 and RC 2) were audited, and `BaseHook` and `CurrencySettler` were in those scopes. We could not machine-read the audit PDFs in the repository, so this is taken from the web pages and not independently confirmed. The repository's own README also states the code has not been audited.
- Standby accrual uses conservative endpoint sampling; intermediate dips are bounded only by `maxAccrualInterval`.
- Sponsor funds are not withdrawable in v1. The sponsor stops spending by setting the rate to zero and should fund in tranches (ADR-021).
- Exit race at crash onset (T18): stress detection uses a short TWAP and lags spot, so holders with already matured tickets can exit in the first minutes of a crash before the lock engages. `liveDepth` nets exits maturing inside the consumer's horizon so the exposure is visible.
- Only the configured `initializer` can initialize the pool, and the fee and tick spacing are fixed in the hook's configuration (ADR-014).
- Consumers should size caps from `liveDepth`, not `committedDepth`. Select `impactBps` for the relevant liquidation-penalty assumption and `horizon` for the required availability window; `SupplyCapAdvisor` is illustrative and does not prescribe either parameter or the multiplier.
- Demo deployments use compressed time windows. They are not production parameters.

## Reporting a vulnerability
Please do not open public issues for security problems. Contact the maintainers privately at the address listed in the repository profile (replace with a real contact before publication). Include a description, impact, a proof of concept if you have one, and affected commits. We aim to acknowledge reports within 72 hours.

## Scope
In scope: contracts in `src/`, scripts that affect deployment safety, and documentation claims that contradict the code. Out of scope: vulnerabilities in dependencies (report upstream), issues requiring unsupported tokens, and attacks needing control of the PoolManager.
