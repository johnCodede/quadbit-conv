# Quadbit Convolution Coprocessor

A **single convolution-layer accelerator** in Verilog, controlled over SPI, that
computes one full CNN layer at a time with **1-bit / ternary weights and no
multipliers** — the "multiply" is replaced by a sign-select mux + negate.

Built and verified end-to-end: full-chip simulation passes with **exact match
against a pure-Python reference** (all `10,816 + 10,816` outputs of a 2-layer
chain), and `verilator --lint-only -Wall` is clean.

```
        ┌─────────────────────────── CO-PROCESSOR ───────────────────────────┐
        │   SPI slave  →  conv_spi_ctrl  →  conv_ctrl (spatial FSM)          │
 SPI   │   (byte       (opcodes +        →  conv_window + frame_buf          │
 4-wire└───────────────►  burst readout)   →  quadbit_layer (PE array)        │
  mode0                  (FSM)            →  out_buf (10,816 × 24-bit)       │
        │   PE = sign-select mux + negate + accumulate. NO multiplier.       │
        └────────────────────────────────────────────────────────────────────┘
              host (Raspberry Pi / testbench) programs weights + frame,
              reads the 26×26×16 feature map, does the inter-layer glue
              (channel-reduce + scale, zero-pad 26→28), then re-programs
              the chip for the next layer.  Layer chaining = host model.
```

## What it does

- **Input:** 28×28×1 (e.g. an MNIST digit), 8-bit unsigned activations.
- **Op:** 3×3 kernel, stride 1, zero-padding, ReLU, **16 filters** → 26×26×16.
- **Weights:** 2-bit "quadbit" codes `{10:+1, 00:0, 01:−1, 11:ctrl}` — so each
  PE tap is `+x`, `0`, or `−x`, accumulated into a 24-bit sum. **No multiplier
  anywhere.**
- **Throughput:** one full layer per run, independent of host read speed; the
  host reads the feature map at its own pace.
- **Interface:** SPI mode 0 (CPOL=0, CPHA=0), byte-framed opcodes, one CS
  transaction per command. `O_READ_BURST` streams the whole feature map in a
  single transaction.

## Status (verified 2026-09)

| Check | Result |
|---|---|
| Full-chip sim, 1 layer | PASS — outputs match `conv_ref.py` exactly |
| 2-layer chain (real MNIST digit) | PASS — all `10,816 + 10,816` outputs exact (out1 sum 290774, out2 sum 140699) |
| 5-image batch (reset-between-images) | PASS — `TESTS=1 PASS=1 FAIL=0` |
| `verilator --lint-only -Wall` | clean (RC=0) |
| Icarus + cocotb 2.1.0 | working testbench, `COCOTB_TEST_MODULES` |

`conv_ref.py` is the **single source of truth** for expected values — the RTL
is validated against it, not against itself.

## Repo layout

```
rtl/      Verilog: top, SPI slave, control FSMs, window/frame generators,
          PE array, buffers. Plus per-block testbenches (tb_*.v).
python/   Driver (spidev-compatible), SPI transport for sim, and the
          cocotb testbenches: tb_smoke, tb_conv_chain, tb_conv_batch.
conv_ref.py      Pure-Python reference (ground truth).
scaling_check.py Scale-factor sweep that selected the >>5 output scaling.
DESIGN.md        Design log: architecture, locked decisions, status.
SPI.md           Byte-level SPI protocol + command reference.
TIMING_PI_VS_CO.md  Host-vs-coprocessor timing + per-image byte/transaction
                    budget.
AREA_TIMING_130NM.md  130 nm area/timing sanity estimate from exact RTL
                    resource counts.
PRIOR_ART.md   Prior-art / patent sweep (datapath is prior art; the system +
               niche are the defensible part).
```

## Run the simulation

Toolchain: Icarus Verilog (`iverilog`/`vvp`), Verilator 5.x (lint), Python
3.12 + cocotb 2.1.0.

```bash
# lint
verilator --lint-only -Wall rtl/quadbit_conv_top.v

# full-chip smoke + chain + batch (cocotb vs Icarus)
# see python/tb_conv_chain.py and python/tb_conv_batch.py for the exact
# COCOTB_TEST_MODULES + VPI flags.
```

## Design notes worth a skim

- **Why no multiplier:** with weights ∈ {−1, 0, +1}, `w·x ∈ {−x, 0, +x}` — a
  3-way mux plus a sign-select adder replaces a full MAC. This is the standard
  binary/ternary-neural-network datapath (see `PRIOR_ART.md` for the prior-art
  position).
- **Why a coprocessor and not an SoC:** the host keeps control flow, model
  glue, and I/O; the chip only does the deterministic conv math. Cheap to
  fabricate, easy to verify, and the SPI bus means any host with a GPIO can
  drive it.
- **Scope (honest):** this is a **single fixed-shape** layer (28×28 in, 16
  filters, 3×3). It is not a general-purpose GEMM engine or a full NN runtime —
  the reference implementation and the proof that the datapath, control, and
  SPI protocol work, end to end.

---

*Single source of truth for values is `conv_ref.py`. All numbers above are
reproducible from the testbenches in `python/`.*
