#!/usr/bin/env python3
"""scaling_check.py — verify the layer-1 -> layer-2 reduction is well-scaled.

Run:  python3 scaling_check.py
Exits 0 if every check passes.

Checks:
  1. frame2 values all fit in unsigned 8 bits (no overflow, no clamp hit
     for this test data — clamp is a safety net, not part of the data).
  2. frame2 border is all zero (pad28 contract).
  3. frame2 interior matches an independently written one-line formula.
  4. frame2 is sensitive: >90% of interior positions non-zero, and the
     dynamic range is usable (not collapsed to a few values).
  5. out2 discriminates weights: conv with layer-2 weights differs from
     conv with layer-1 weights (proves reprogramming changes the result).
  6. Scale sweep: prints frame2/out2 stats for shifts 3..8 so the chosen
     shift (conv_ref.SHIFT) is defensible.
"""
import sys
import conv_ref as R

FAILS = []

def check(name, cond, detail=""):
    tag = "PASS" if cond else "FAIL"
    print(f"[{tag}] {name}" + (f"  ({detail})" if detail else ""))
    if not cond:
        FAILS.append(name)

out1 = R.conv2d(R.frame1, R.w1)
red  = R.reduce(out1)
frame2 = R.pad28(red)
out2   = R.conv2d(frame2, R.w2)

# 1. 8-bit fit -------------------------------------------------------------
flat = [frame2[r][c] for r in range(R.ROWS) for c in range(R.COLS)]
check("frame2 fits in 8 bits", all(0 <= v <= 255 for v in flat),
      f"min={min(flat)} max={max(flat)}")
saturated = sum(1 for v in flat if v == 255)
check("no saturation at 255", saturated == 0, f"{saturated} saturated cells")

# 2. border zeros -----------------------------------------------------------
border = [frame2[0][c] for c in range(R.COLS)] + \
         [frame2[R.ROWS-1][c] for c in range(R.COLS)] + \
         [frame2[r][0] for r in range(R.ROWS)] + \
         [frame2[r][R.COLS-1] for r in range(R.ROWS)]
check("frame2 border all zero", all(v == 0 for v in border),
      f"{sum(1 for v in border if v)} non-zero border cells")

# 3. interior matches independent one-liner ---------------------------------
mismatch = 0
for r in range(1, R.OUT+1):
    for c in range(1, R.OUT+1):
        s = sum(out1[r-1][c-1][f] for f in range(R.N))
        expect = min(255, s >> R.SHIFT)
        if frame2[r][c] != expect:
            mismatch += 1
check("interior matches independent formula", mismatch == 0,
      f"{mismatch} mismatched cells")

# 4. sensitivity ------------------------------------------------------------
interior = [frame2[r][c] for r in range(1, R.OUT+1) for c in range(1, R.OUT+1)]
nz = sum(1 for v in interior if v != 0)
frac = nz / len(interior)
check("frame2 interior >90% non-zero", frac > 0.90, f"{nz}/{len(interior)} = {frac:.1%}")
distinct = len(set(interior))
check("frame2 dynamic range usable (>=20 distinct values)", distinct >= 20,
      f"{distinct} distinct values, mean={sum(interior)/len(interior):.1f}")

o2flat = [out2[r][c][f] for r in range(R.OUT) for c in range(R.OUT) for f in range(R.N)]
check("out2 non-zero", sum(o2flat) > 0, f"sum={sum(o2flat)}, max={max(o2flat)}")

# 5. weight discrimination ----------------------------------------------------
out2_with_w1 = R.conv2d(frame2, R.w1)
same = all(out2[r][c][f] == out2_with_w1[r][c][f]
           for r in range(R.OUT) for c in range(R.OUT) for f in range(R.N))
check("layer-2 weights change the result (reprogramming matters)", not same,
      f"sum(w2)={sum(o2flat)} vs sum(w1-on-frame2)={sum(x for x in (out2_with_w1[r][c][f] for r in range(R.OUT) for c in range(R.OUT) for f in range(R.N)))}")

# 6. scale sweep ---------------------------------------------------------------
print("\nScale sweep (shift: frame2 nz% / max / out2 sum):")
for sh in range(3, 9):
    f2 = [[min(255, sum(out1[r][c][f] for f in range(R.N)) >> sh)
           for c in range(R.OUT)] for r in range(R.OUT)]
    fr = R.pad28(f2)
    o2 = R.conv2d(fr, R.w2)
    fl = [v for row in f2 for v in row]
    print(f"  >>{sh}:  nz={sum(1 for v in fl if v)}/{len(fl)}  "
          f"max={max(fl)}  sat={sum(1 for v in fl if v==255)}  "
          f"out2_sum={sum(x for x in (o2[r][c][f] for r in range(R.OUT) for c in range(R.OUT) for f in range(R.N)))}")

print()
if FAILS:
    print(f"=== {len(FAILS)} CHECK(S) FAILED: {FAILS} ===")
    sys.exit(1)
print("=== ALL SCALING CHECKS PASSED ===")
