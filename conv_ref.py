# conv_ref.py — Python reference model for the Quadbit spatial convolution.
#
# Single source of truth for the layer-by-layer chain. The Verilog
# testbench (tb_quadbit_conv_top.v) reproduces EXACTLY these definitions:
#   * conv2d(frame, weights)  : 28x28 single-channel, 3x3, 16 filters,
#                               zero-pad, ReLU (matches on-chip datapath)
#   * reduce(out)             : host-side channel reduction 16ch -> 1ch
#   * pad28(next26)           : 26x26 -> 28x28 (1-pixel zero border)
#
# Quadbit weight encoding (2 bits):
#   2'b10 -> +1   (code 2)
#   2'b00 ->  0   (code 0)
#   2'b01 -> -1   (code 1)
#   2'b11 -> ctrl (treated as 0 in the math; not used in these tests)

ROWS = 28
COLS = 28
N    = 16          # number of filters
OUT  = 26          # 28 - 3 + 1
OUT_TOTAL = OUT * OUT * N   # output elements per layer (26*26*16 = 10816)

def quadbit_val(code):
    if code == 2: return 1    # 10
    if code == 1: return -1   # 01
    return 0                  # 00 (and 11 -> treated as 0)

# ---- Layer weights ---------------------------------------------------------
# Layer 1: w = (t + f) % 3
w1 = [[0]*N for _ in range(9)]
for t in range(9):
    for f in range(N):
        w = (t + f) % 3
        w1[t][f] = 2 if w == 2 else (0 if w == 1 else 1)

# Layer 2: w = (2t + f) % 3   (deliberately different from layer 1)
w2 = [[0]*N for _ in range(9)]
for t in range(9):
    for f in range(N):
        w = (2*t + f) % 3
        w2[t][f] = 2 if w == 2 else (0 if w == 1 else 1)

# ---- Input frame for layer 1 ---------------------------------------------
frame1 = [[0]*COLS for _ in range(ROWS)]
for r in range(ROWS):
    for c in range(COLS):
        frame1[r][c] = (r * COLS + c) & 0xFF

# ---- Convolution (matches on-chip: zero-pad, ReLU) -----------------------
def conv2d(frame, weights):
    out = [[[0]*N for _ in range(OUT)] for _ in range(OUT)]
    for r in range(OUT):
        for c in range(OUT):
            for f in range(N):
                acc = 0
                for t in range(9):
                    dr = t // 3 - 1
                    dc = t % 3 - 1
                    rr, cc = r + dr, c + dc
                    px = 0
                    if 0 <= rr < ROWS and 0 <= cc < COLS:
                        px = frame[rr][cc]
                    acc += quadbit_val(weights[t][f]) * px
                out[r][c][f] = max(0, acc)
    return out

# ---- Host-side reduction: 16ch -> 1ch ------------------------------------
# Scale: channel sums top out at ~4050 with these test weights; >>5 maps
# that into a healthy 8-bit range (max 126, no saturation) while keeping
# the frame mostly non-zero. Clamp to 255 keeps the definition valid for
# larger/real networks.
SHIFT = 5
def reduce(out):
    # next[r][c] = min(255, (sum_f out[r][c][f]) >> SHIFT)
    nxt = [[0]*OUT for _ in range(OUT)]
    for r in range(OUT):
        for c in range(OUT):
            s = 0
            for f in range(N):
                s += out[r][c][f]
            nxt[r][c] = min(255, s >> SHIFT)
    return nxt

# ---- Pad 26x26 -> 28x28 (1-pixel zero border) -----------------------------
def pad28(next26):
    fr = [[0]*COLS for _ in range(ROWS)]
    for r in range(1, OUT+1):
        for c in range(1, OUT+1):
            fr[r][c] = next26[r-1][c-1]
    return fr

# ---- Run the chain ---------------------------------------------------------
if __name__ == "__main__":
    out1 = conv2d(frame1, w1)
    frame2 = pad28(reduce(out1))
    out2 = conv2d(frame2, w2)

    def report(name, out):
        tot = 0
        for r in range(OUT):
            for c in range(OUT):
                for f in range(N):
                    tot += out[r][c][f]
        print(f"{name}[0,0,0]      = {out[0][0][0]}")
        print(f"{name}[0,0,15]     = {out[0][0][15]}")
        print(f"{name}[1,1,1]      = {out[1][1][1]}")
        print(f"{name}[12,12,7]    = {out[12][12][7]}")
        print(f"{name}[25,25,15]   = {out[25][25][15]}")
        print(f"{name} sum         = {tot}")

    report("out1", out1)
    report("out2", out2)

    # Also show a couple of intermediate reduction values for cross-checking.
    red = reduce(out1)
    print("reduce[0,0]    =", red[0][0])
    print("reduce[25,25]  =", red[25][25])
    print("frame2[1,1]    =", frame2[1][1])
    print("frame2[0,0]    =", frame2[0][0], "(border, expect 0)")
else:
    # Import side-effect-free: keep the chain objects for consumers.
    out1   = conv2d(frame1, w1)
    frame2 = pad28(reduce(out1))
    out2   = conv2d(frame2, w2)
