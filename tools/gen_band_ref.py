#!/usr/bin/env python3
"""Generates test/data/band_ticks_ref.json: the off-chain reference for BandMath (docs/MATH.md §2, ADR-035).

For bps in [1, 2500]: delta = ln(10000 / (10000 - bps)) / ln(1.0001), in ticks, computed with 80-digit decimals.
Stores floor(delta), round-half-up(delta) and delta in WAD (floor of delta * 1e18) as decimal strings.
Run: python3 tools/gen_band_ref.py
"""
import json
from decimal import Decimal, getcontext, ROUND_FLOOR, ROUND_HALF_UP
from pathlib import Path

getcontext().prec = 80
LN_TICK = Decimal("1.0001").ln()
WAD = Decimal(10) ** 18

floors, nearest, wads = [], [], []
for bps in range(1, 2501):
    delta = (Decimal(10000) / Decimal(10000 - bps)).ln() / LN_TICK
    floors.append(str(int(delta.to_integral_value(rounding=ROUND_FLOOR))))
    nearest.append(str(int(delta.to_integral_value(rounding=ROUND_HALF_UP))))
    wads.append(str(int((delta * WAD).to_integral_value(rounding=ROUND_FLOOR))))

out = {
    "description": "BandMath reference for bps 1..2500 (index 0 is bps 1). See tools/gen_band_ref.py.",
    "ln_1_0001_wad_floor": str(int((LN_TICK * WAD).to_integral_value(rounding=ROUND_FLOOR))),
    "floor": floors,
    "nearest": nearest,
    "wad": wads,
}
path = Path(__file__).resolve().parent.parent / "test" / "data" / "band_ticks_ref.json"
path.write_text(json.dumps(out, indent=0) + "\n")
print("wrote", path, "ln_1_0001_wad_floor =", out["ln_1_0001_wad_floor"])
