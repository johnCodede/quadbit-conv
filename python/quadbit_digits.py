"""quadbit_digits.py — 5 distinct deterministic 28x28 (0..255) test images.

Single source of the batch-test input set, shared by:
  * simulation:  tb_conv_batch.py
  * Raspberry Pi: same file, unchanged (pure Python, no cocotb imports)

Images are deliberately DISTINCT and ink-rich so that a reset failure
(stale frame_buf pixels or un-cleared accumulators leaking from image N
into image N+1) shows up as an output mismatch:

  image0  real MNIST digit (digits/digit0.txt) — fallback: filled disk
  image1  thick vertical bar
  image2  thick diagonal band
  image3  thick ring
  image4  seeded full-field noise (max entropy)
"""
import os

ROWS = 28
COLS = 28

_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "digits")


def _zero():
    return [[0] * COLS for _ in range(ROWS)]


def _load_real0():
    """Real MNIST digit0 if present and well-formed, else None."""
    p = os.path.join(_DIR, "digit0.txt")
    if not os.path.exists(p):
        return None
    grid = []
    with open(p) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            grid.append([int(x) for x in line.split()])
    if len(grid) == ROWS and all(len(row) == COLS for row in grid):
        return grid
    return None


def _disk():
    """Filled disk, center (13.5,13.5), radius ~8.5 — image0 fallback."""
    g = _zero()
    for r in range(ROWS):
        for c in range(COLS):
            if (r - 13.5) ** 2 + (c - 13.5) ** 2 <= 72:
                g[r][c] = 255
    return g


def _bar():
    """Thick vertical bar, cols 10..17, rows 3..24."""
    g = _zero()
    for r in range(3, 25):
        for c in range(10, 18):
            g[r][c] = 220
    return g


def _diagonal():
    """Thick diagonal band, |r-c| <= 3."""
    g = _zero()
    for r in range(ROWS):
        for c in range(COLS):
            if abs(r - c) <= 3:
                g[r][c] = 200
    return g


def _ring():
    """Thick ring, radius ~7.4..9.0 around center."""
    g = _zero()
    for r in range(ROWS):
        for c in range(COLS):
            d2 = (r - 13.5) ** 2 + (c - 13.5) ** 2
            if 55 <= d2 <= 81:
                g[r][c] = 240
    return g


def _noise(seed=0xC0FFEE):
    """Seeded LCG full-field noise (max entropy — best reset-leak detector)."""
    g = _zero()
    x = seed & 0x7FFFFFFF
    for r in range(ROWS):
        for c in range(COLS):
            x = (x * 1103515245 + 12345) & 0x7FFFFFFF
            g[r][c] = (x >> 8) & 0xFF
    return g


NAMES = ["digit (real MNIST)", "vertical bar", "diagonal band",
         "ring", "noise"]


def make_images():
    """Return the 5 distinct 28x28 test images (list of [row][col] ints)."""
    img0 = _load_real0()
    if img0 is None:
        img0 = _disk()
        NAMES[0] = "filled disk (digit0.txt absent)"
    return [img0, _bar(), _diagonal(), _ring(), _noise()]


def ink(grid):
    """Count of 'lit' pixels (>32) — useful sanity printout."""
    return sum(1 for row in grid for v in row if v > 32)


def maxpx(grid):
    return max(max(row) for row in grid)


if __name__ == "__main__":
    for i, g in enumerate(make_images()):
        print(f"image{i}: {NAMES[i]:<22} ink={ink(g):4d}  max={maxpx(g)}")
