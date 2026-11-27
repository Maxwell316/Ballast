#!/usr/bin/env python3
"""Mutation sanity runner (not a CI gate). Applies one scratch mutation at a time to a source file, runs the fast test
suite, records whether any test failed ("caught") and restores the file. Usage: tools/mutate.py [label-substring].

Each mutation is a (label, file, old, new) quadruple; `old` must occur exactly once. Results are appended to
docs/MUTATION_LOG.md by hand after review (a surviving mutant is either a test gap, to be fixed, or an equivalent
mutant, to be explained)."""
import os
import signal
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
V = "src/BallastVaults.sol"
S = "src/BallastStandby.sol"
L = "src/periphery/BallastLens.sol"
SH = "src/BallastShares.sol"
H = "src/BallastHook.sol"
O = "src/libraries/Observations.sol"
D = "src/libraries/DepthMath.sol"

MUTATIONS = [
    ("deposit rounds liquidity down", V, "uint128 dl =\n                seeding ? liqs[i] : _u128(VaultMath.ceilShare(", "uint128 dl =\n                seeding ? liqs[i] : _u128(VaultMath.floorShare("),
    ("redeem rounds liquidity up", V, "uint128 dl = _u128(VaultMath.floorShare(ps[i].liquidity, t.shares, supply));", "uint128 dl = _u128(VaultMath.ceilShare(ps[i].liquidity, t.shares, supply));"),
    ("maturity check off by one", V, "if (_now() < t.maturity) revert TicketNotMature(t.maturity);", "if (_now() <= t.maturity) revert TicketNotMature(t.maturity);"),
    ("claim ignores the lock", V, "if (e.lockActive) {\n            revert StressLockActive(e.lockedUntil);\n        }\n        if (_now() < t.maturity)", "if (_now() < t.maturity)"),
    ("deposit allowed outside calm", V, "if (e.state != LockState.CALM) {\n            if (e.lockActive) {", "if (false) {\n            if (e.lockActive) {"),
    ("breach flag one second late", V, "nowTs >= vd.coverageLostSince + _rerangeGrace", "nowTs > vd.coverageLostSince + _rerangeGrace"),
    ("accrual ignores breach", V, "if (vd.breachSince == 0 && dt != 0) {", "if (dt != 0) {"),
    ("rerange coverage check removed", V, "if (env.committed < vd.commitment) {\n            revert CoverageBelowCommitment(env.committed, vd.commitment);\n        }", ""),
    ("commitment decrease immediate", V, "vd.pendingCommitment = newCommitment;\n            vd.pendingCommitmentAt = _now() + _exitNotice;", "vd.commitment = newCommitment;\n            vd.pendingCommitmentAt = _now() + _exitNotice;"),
    ("requestRedeem does not escrow", V, "shareToken.move(msg.sender, address(this), vaultId, shares);", ""),
    ("curator cut credited to idle", V, "vd.owed1 += _u128(toCurator);\n            vd.idle1 += _u128(toIdle);", "vd.owed1 += _u128(toIdle);\n            vd.idle1 += _u128(toCurator);"),
    ("reward not capped by fund", S, "reward = RewardMath.capToFund(RewardMath.accrue(eligibleDepth, rate, dt), fund);", "reward = RewardMath.accrue(eligibleDepth, rate, dt);"),
    ("eligible uses the larger sample", V, "env.sample < dExtra ? env.sample : dExtra", "env.sample > dExtra ? env.sample : dExtra"),
    ("live depth not netted for exits", L, "total += e >= s ? 0 : FixedPointMathLib.fullMulDiv(l, s - e, s);", "total += l;"),
    ("exit netting ignores earliestRelease", L, "bool released = hook.stressInfo().earliestRelease <= limit;", "bool released = true;"),
    ("lens flips the collateral direction", L, "_collateralIs0 = Currency.unwrap(c.collateral) < Currency.unwrap(c.quote);", "_collateralIs0 = Currency.unwrap(c.collateral) > Currency.unwrap(c.quote);"),
    ("DepthMath committed rounds up", D, "uint160 sqrtHi = TickMath.getSqrtPriceAtTick(hi);\n        return collateralIs0\n            ? SqrtPriceMath.getAmount0Delta(sqrtLo, sqrtHi, liquidity, false)\n            : SqrtPriceMath.getAmount1Delta(sqrtLo, sqrtHi, liquidity, false);", "uint160 sqrtHi = TickMath.getSqrtPriceAtTick(hi);\n        return collateralIs0\n            ? SqrtPriceMath.getAmount0Delta(sqrtLo, sqrtHi, liquidity, true)\n            : SqrtPriceMath.getAmount1Delta(sqrtLo, sqrtHi, liquidity, true);"),
    ("DepthMath live rounds up", D, "if (sqrtHi <= sqrtLo) return 0;\n        return collateralIs0\n            ? SqrtPriceMath.getAmount0Delta(sqrtLo, sqrtHi, liquidity, false)\n            : SqrtPriceMath.getAmount1Delta(sqrtLo, sqrtHi, liquidity, false);", "if (sqrtHi <= sqrtLo) return 0;\n        return collateralIs0\n            ? SqrtPriceMath.getAmount0Delta(sqrtLo, sqrtHi, liquidity, true)\n            : SqrtPriceMath.getAmount1Delta(sqrtLo, sqrtHi, liquidity, true);"),
    ("lens netting rounds up", L, "FixedPointMathLib.fullMulDiv(l, s - e, s)", "FixedPointMathLib.fullMulDivUp(l, s - e, s)"),
    ("shares mint open to anyone", SH, "function mint(address to, uint256 id, uint256 amount) external onlyVaults {", "function mint(address to, uint256 id, uint256 amount) external {"),
    ("standby rate open to anyone", S, "function setStandbyRate(uint128 rate) external {\n        if (msg.sender != _sponsor) revert NotSponsor(msg.sender);\n", "function setStandbyRate(uint128 rate) external {\n"),
    ("curator check removed", V, "if (msg.sender != vd.curator) revert NotCurator(msg.sender);", ""),
    ("vault op allowed after a swap", H, "if (Transient.get(Transient.SWAPPED)) revert SwapInSameTransaction();", ""),
    ("swap allowed after a vault op", H, "if (Transient.get(Transient.VAULT_OP)) revert VaultOpInSameTransaction();", ""),
    ("reentrancy lock not enforced", V, "function _lock() private {\n        if (Transient.get(Transient.LOCK)) revert Reentrancy();\n", "function _lock() private {\n"),
    ("fees credited to idle without claims", V, "_toClaims(_c0(), f0);\n        _toClaims(_c1(), f1);", "_toClaims(_c1(), f1);"),
    ("oracle cumulative off by one", O, "int256 delta = int256(preSwapTick) * int256(uint256(nowTs - st.lastSwapTs));", "int256 delta = int256(preSwapTick) * int256(uint256(nowTs - st.lastSwapTs)) + 1;"),
    ("deposit idle slice rounds down", V, "s0 = VaultMath.ceilShare(vd.idle0, shares, supply);\n            s1 = VaultMath.ceilShare(vd.idle1, shares, supply);", "s0 = VaultMath.floorShare(vd.idle0, shares, supply);\n            s1 = VaultMath.floorShare(vd.idle1, shares, supply);"),
    ("dust cap removed", V, "if (uint256(-net) - idle > RERANGE_DUST_CAP) revert InsufficientIdle();", ""),
    ("fees not crystallized before deposit", V, "env = _env(c);\n        _crystallize(c.v, env);\n        _flush(c.v, env);\n        _measure(c.v, env);\n        _accrue(c.v, env, type(uint128).max);", "env = _env(c);\n        _measure(c.v, env);\n        _accrue(c.v, env, type(uint128).max);"),
]


def run(cmd):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)


# Mutations also run against the handler-based invariant suite (`--invariants`), where the failing invariant is named.
INVARIANT_LABELS = {
    "deposit rounds liquidity down",
    "claim ignores the lock",
    "rerange coverage check removed",
    "vault op allowed after a swap",
    "swap allowed after a vault op",
    "fees credited to idle without claims",
    "oracle cumulative off by one",
    "deposit idle slice rounds down",
    "lens flips the collateral direction",
}


def main():
    # Restore the mutated file even when the runner is terminated (the `finally` below runs on SystemExit).
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    args = [a for a in sys.argv[1:] if a != "--invariants"]
    invariants = "--invariants" in sys.argv[1:]
    picks = args[0].split("|") if args else [""]
    results = []
    for label, f, old, new in MUTATIONS:
        if not any(p in label for p in picks):
            continue
        if invariants and label not in INVARIANT_LABELS:
            continue
        path = ROOT / f
        src = path.read_text(encoding="utf-8")
        if src.count(old) != 1:
            results.append((label, f"SKIPPED: pattern occurs {src.count(old)} times"))
            print(results[-1], flush=True)
            continue
        try:
            path.write_text(src.replace(old, new), encoding="utf-8")
            if invariants:
                r = subprocess.run(
                    ["forge", "test", "--match-contract", "BallastInvariantTest_"],
                    cwd=ROOT, capture_output=True, text=True,
                    env={**os.environ, "FOUNDRY_INVARIANT_RUNS": "64", "FOUNDRY_INVARIANT_DEPTH": "64"})
            elif os.environ.get("MUTATE_MATCH_PATH"):
                # Narrow run for mutations whose guards have a dedicated suite (full runs take over ten minutes each).
                r = run(["forge", "test", "--match-path", os.environ["MUTATE_MATCH_PATH"]])
            else:
              r = run(["forge", "test", "--no-match-contract",
                     "InvariantTest|Totality|HooksOnChain|DeployBallastScript|HookOnlyLiquidityFork|ObservationsDifferential|ObservationsCursor|BallastDepthDifferential|SizesTest|VaultGasTest"])
            out = r.stdout + r.stderr
            if "Compiler run failed" in out:
                status = "COMPILE ERROR"
            else:
                failed = [l for l in out.splitlines() if l.startswith("[FAIL")]
                if invariants:
                    names = sorted({l.split("] ")[-1].split(" ")[0].split("(")[0] for l in failed})
                    status = f"caught by {len(failed)} test(s): {', '.join(names)}" if failed else "SURVIVED"
                else:
                    status = f"caught by {len(failed)} test(s): " + (failed[0][:110] if failed else "") if failed else "SURVIVED"
        finally:
            path.write_text(src, encoding="utf-8")
        results.append((label, status))
        print(results[-1], flush=True)
    print("\n".join(f"{l}: {s}" for l, s in results))


if __name__ == "__main__":
    main()
