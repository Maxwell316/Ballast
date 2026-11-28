# Compliance waivers

Requirements that are guidance for documentation or for consumers and cannot be asserted by a test. Each line is
`- ID: reason`; `tools/compliance.py --check` fails on a waiver whose ID now has a test.

- R-VIEW-5: Consumer policy guidance: size caps from `liveDepth`, not anchor-based `committedDepth`, and choose impact, horizon, and multiplier to fit the consumer's risk policy. These choices cannot be imposed by a contract test. The distinction and parameter responsibilities are stated in `IBallastDepthOracle` NatSpec, README, and SECURITY. The reference implementation is still tested: `SupplyCapAdvisor.t.sol` pins its result to independent depth evidence, and `Crash.t.sol` shows a matured exit is netted while calm but not while the lock holds it.
