# Compliance waivers

Requirements that are guidance for documentation or for consumers and cannot be asserted by a test. Each line is
`- ID: reason`; `tools/compliance.py --check` fails on a waiver whose ID now has a test.

- R-VIEW-5: Consumer guidance (size caps from `liveDepth`, not `committedDepth`). It is stated in the NatSpec of `IBallastDepthOracle`, in `SupplyCapAdvisor`, in the README and in SECURITY; there is no behaviour to assert. The advisor's use of `liveDepth` is tested in `SupplyCapAdvisor.t.sol`.
