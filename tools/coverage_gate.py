#!/usr/bin/env python3
"""Coverage gate over an lcov file. Usage: coverage_gate.py lcov.info PREFIX [--lines 95] [--branches 90].

Aggregates line and branch coverage for source files whose path starts with PREFIX (for example src/libraries/)
and exits non-zero if below the thresholds.
"""
import sys

def main():
    args = sys.argv[1:]
    lcov, prefix = args[0], args[1]
    lines_min = float(args[args.index("--lines") + 1]) if "--lines" in args else 95.0
    br_min = float(args[args.index("--branches") + 1]) if "--branches" in args else 90.0
    lf = lh = brf = brh = 0
    cur = None
    for raw in open(lcov, encoding="utf-8"):
        raw = raw.strip()
        if raw.startswith("SF:"):
            cur = raw[3:]
        elif cur and cur.startswith(prefix):
            if raw.startswith("LF:"): lf += int(raw[3:])
            elif raw.startswith("LH:"): lh += int(raw[3:])
            elif raw.startswith("BRF:"): brf += int(raw[4:])
            elif raw.startswith("BRH:"): brh += int(raw[4:])
    lp = 100.0 * lh / lf if lf else 100.0
    bp = 100.0 * brh / brf if brf else 100.0
    print(f"{prefix}: lines {lh}/{lf} = {lp:.1f}% (min {lines_min}), branches {brh}/{brf} = {bp:.1f}% (min {br_min})")
    if lp < lines_min or bp < br_min:
        sys.exit(1)

if __name__ == "__main__":
    main()
