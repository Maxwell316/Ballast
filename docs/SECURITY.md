# Security Policy

Ballast custodies liquidity. Treat it as unaudited software unless an audit report is linked here.

## Status
- **Audits:** none yet.
- **Deployments:** testnet only (see `deployments/`). Do not deposit funds you cannot afford to lose.

## Trust model (summary)
- No owner, no pause, no upgrade. Funds move only under the rules in `docs/SPEC.md`.
- The sponsor can fund and set a bounded standby rate. It cannot touch depositor funds.
- Curators manage ranges and earn a capped fee. They cannot withdraw depositor funds.
- Depositors accept an **exit notice** and a **bounded stress lock**. The lock traps price risk by design; Ballast does not protect against price losses.

## Known limitations
- Supported tokens: standard ERC-20 only. Fee-on-transfer, rebasing, blocklist and callback tokens are unsupported.
- Tokens sent to the hook outside the documented functions are not accounted for and cannot be recovered.
- A cold or very sparse pool has no stress protection until its oracle is warm.
- A well-capitalized attacker can trigger or delay a lock in a shallow pool (see `docs/THREAT_MODEL.md`, T3 and T4).
- Depth is counted equally anywhere in the band (T5).
- Standby accrual uses conservative endpoint sampling; intermediate dips are bounded only by `maxAccrualInterval`.
- Demo deployments use compressed time windows. They are not production parameters.

## Reporting a vulnerability
Please do not open public issues for security problems. Contact the maintainers privately at the address listed in the repository profile (replace with a real contact before publication). Include a description, impact, a proof of concept if you have one, and affected commits. We aim to acknowledge reports within 72 hours.

## Scope
In scope: contracts in `src/`, scripts that affect deployment safety, and documentation claims that contradict the code. Out of scope: vulnerabilities in dependencies (report upstream), issues requiring unsupported tokens, and attacks needing control of the PoolManager.
