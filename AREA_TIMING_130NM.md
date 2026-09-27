# Quadbit Conv Coprocessor — 130 nm Area / Timing Sanity Check

Date: 2026-09-25 · Author: Jeff (AI)
Method: exact resource counts read from the RTL → mapped to 130 nm area with
published density rules of thumb. Cross-checked with a clean Verilator
elaboration of `quadbit_conv_top` (RC=0; expression stats corroborate scale:
144 PE negations, ~2.5k memory array-selects). No 130 nm standard-cell library
or P&R tool (yosys/abc) available, so this is an **estimate**, not a sign-off
number. For real numbers: Design Compiler/Genus + Innovus/Virtuoso on a 130 nm
PDK (e.g. UMC 130 / TSMC 0.13).

## 1. Resource inventory (exact, from RTL)

| Block | Storage (bits) | Notes |
|---|---:|---|
| `out_buf` | **259,584** | 26×26 × 16 filt × 24 b = 10,816 × 24. **Dominant.** +24 b `r_data` reg |
| `frame_buf` | 6,272 | 28×28 × 8 b input frame. +16 b `wcount` |
| `quadbit_layer` | 712 | weights 9×16×2=288, acc 16×24=384, st/k_en/n_en/ctrl/x_idx ≈ 40 |
| `conv_spi_ctrl` | 131 | SPI command FSM + latched args |
| `conv_ctrl` | 44 | spatial FSM, position/tap/out-sel counters |
| `spi_slave` | 23 | RX/TX shift registers |
| **Total storage** | **≈ 266,800 bits** | **out_buf = 97.3% of it** |

- **Processing elements:** 144 (`pe_quadbit`, K×N = 9×16) — pure sign-select mux + negate, no multiplier.
- **Accumulators:** 16 × 24-bit adders (per-output `acc += sext(pe_out)`).
- **Logic FFs (excluding the two big memories):** ≈ 950.
- **Combinational (hand count, excl. memory read ports):** ≈ 7–8 k gates
  (144 PEs ≈ 5.8 k, 16×24-bit adders ≈ 1.2 k, 3 FSMs + window ≈ 0.7 k).

## 2. 130 nm area estimate

Density assumptions (130 nm typical, stated so the numbers are reproducible):
- NAND2-eq gate ≈ **0.05 µm²** (range 0.03–0.06)
- D flip-flop ≈ **0.18 µm²** (range 0.12–0.25)
- SRAM 1T/2T bitcell ≈ **0.09 µm²/bit** (range 0.06–0.12)

**Scenario A — all flip-flops (no embedded SRAM), worst case:**
- 266,800 FF × 0.18 = 48.0 mm² + ~8 k gates × 0.05 = 0.4 mm² → **≈ 48 mm²**

**Scenario B — SRAM for `frame_buf` + `out_buf` (realistic 130 nm):**
- `out_buf`: 259,584 × 0.09 = **23.4 mm²** (≈ 91% of total)
- `frame_buf`: 6,272 × 0.09 = 0.56 mm²
- logic FFs: 950 × 0.18 = 0.17 mm²
- combinational: ~8 k × 0.05 = 0.4 mm²
- **Total ≈ 24.5 mm²** → die ≈ **5.0 × 5.0 mm**

> **Bottom line: ~25 mm² realistic / ~48 mm² worst-case. The 32 KB `out_buf`
> feature-map buffer is ~90% of the die.**

## 3. Timing (critical path)

Per `x_valid` cycle in `quadbit_layer`, the longest path is:

`x_data (8b) → [PE negate + 3:1 mux] (9b) → sign-extend → 24-bit adder → acc FF`

- The **24-bit ripple-carry accumulator adder is the bottleneck** (~60 gate levels);
  the PE adds ~5–8 levels. Total ≈ **65–70 gate levels**.
- 130 nm gate delay: ~40 ps (fast) / ~70 ps (typ) / ~120 ps (slow) per level.
  → **~350 MHz fast / ~200 MHz typ / ~120 MHz slow.**

**Comfortably meets the 150–200 MHz target in SPI.md** at 130 nm.

## 4. Throughput sanity

Per 28×28 conv position (`conv_ctrl` FSM):
`TAP_SETUP 1 + TAP_DRIVE 9 + WAIT_MAC 1 + READOUT 16 + NEXT_POS 1 = 28 cycles`
Over 26×26 = 676 positions → **≈ 18,900 cycles per conv layer.**

- @100 MHz ≈ **0.19 ms** · @150 MHz ≈ 0.13 ms · @200 MHz ≈ 0.095 ms

## 5. Verdict

- **Feasible at 130 nm — yes, comfortably.** ~25 mm² die, 100–200 MHz, ~0.2 ms/conv.
- **Area is memory-bound, not logic-bound.** The 144-PE MAC array + FSMs are a
  few mm² at most; the 32 KB output buffer is the whole story.

## 6. Optimization levers (if we want a smaller die)

1. **`ACC_W` 24 → 13 bits.** Max conv sum = 9 × 255 = **2295** → needs only
   signed **13 bits**. 24-bit width is inherited from the dense engine
   (K=784, where it's right). Dropping to 13 b **halves `out_buf` (32 KB→16 KB)**
   and **halves the accumulator adder depth** (timing win). Realistic die
   ~25 mm² → **~14 mm²**. *Largest single win.*
   **Decision (John, 2026-09-25): NOT applied.** Keep `ACC_W=24` so the same
   engine can host other (wider-accumulation) models during bring-up. This lever
   stays available if a smaller die is later required.
2. **Stream outputs to the host** (O_READ) instead of buffering the full feature
   map — removes `out_buf` almost entirely if the host reads as the engine
   produces. Protocol change.
3. `frame_buf` (0.56 mm²) is already small; not worth touching.

*Recommendation: if a smaller die becomes a hard requirement, lever #1 (ACC_W=13)
is a one-parameter change with both area and timing upside and no protocol impact.
**As of 2026-09-25 John has chosen to keep ACC_W=24** for model generality, so
lever #1 is intentionally left unapplied. Lever #2 (stream outputs) only if the
die must drop below ~10 mm².*
