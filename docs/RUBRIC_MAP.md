# Rubric Map

A facts-only checklist mapping each judging criterion to evidence in this repository. It is not a presentation script. Update the **Status** column honestly as work completes.

| Criterion | What judges look for | Evidence in repo | Status |
|---|---|---|---|
| **Original Idea** | Novel primitive or use-case; hard to find precedent | README "What is new"; `docs/ECONOMICS.md` §1; precedent notes: time-locked liquidity exists, the new elements are the stress-gated lock, pool-wide committed depth and lender-facing views | ☐ |
| **Unique Execution: v4 primitives** | Meaningful use of hook callbacks, flash accounting, etc. | `getHookPermissions` (5 callbacks); hook-only liquidity via `beforeAdd/RemoveLiquidity`; atomic `rerange` through `unlock`; PoolManager claims for idle custody; ERC-6909 shares; transient storage guards | ☐ |
| **Unique Execution: engineering** | `BaseHook`, sensible decisions, solid tests | `BaseHook` inheritance; pure libraries; custom errors and events; `docs/DECISIONS.md`; invariants INV-1…14; fuzz and differential tests; gas budgets; Slither notes; coverage report | ☐ |
| **Impact** | Real-world effect at scale; market size; improvement for LPs, traders, protocols | `docs/ECONOMICS.md`; cited Aave governance threads; `SupplyCapAdvisor`; simulation results vs control | ☐ |
| **Functionality** | Working deployment (ideally Unichain Sepolia), passing tests, end-to-end demo | `deployments/<chainId>.json`; verified contracts; CI badge; scenario tests; `RunCrash` script and recorded transactions | ☐ |
| **Presentation / Pitch** | Clarity, why before what, own voice; AI-produced presentations are marked down | Human-owned. The repo supports it with README, diagrams (`docs/ARCHITECTURE.md`), and results tables | n/a |

## Facts sheet for the human presenter (technical facts only)

- One hook instance per pool; all liquidity is hook-owned, so pool depth equals committed depth.
- Shares are proportional and in kind; no price oracle in minting or redeeming.
- Exits: notice, then claim; frozen during stress up to a bounded maximum; the lock cannot re-arm without returning to calm.
- Standby fee is paid in the quote currency to vaults, per second, on conservatively sampled committed depth; it stops on coverage breach.
- Depth views: `committedDepth`, `liveDepth(impactBps, horizon)`, `lockState`, curator record counters.
- Known limitations: see `SECURITY.md` and `docs/THREAT_MODEL.md`.
- Evidence to point at: test names for G-1…G-6, invariant suite, deployment manifest, simulation table.
