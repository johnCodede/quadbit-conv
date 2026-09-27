# Quadbit Coprocessor — Design Log

## Status (2026-09-25)
- **Single-layer 3×3 conv coprocessor COMPLETE**: full-chip sim PASS, `verilator --lint-only -Wall` clean.
- **2-layer reference + inter-layer scaling VERIFIED**: `conv_ref.py` (single source of truth) + `scaling_check.py` (scale sweep, all PASS; `>>5` chosen).
- **2-layer chain testbench COMPLETE**: `python/tb_conv_chain.py` — real MNIST digit → layer 1 → host `reduce(>>5)+pad28` → `OP_RESET` → layer 2 → **all 10,816 + 10,816 outputs match `conv_ref.py` exactly** (out1 sum 290774, out2 sum 140699). Verified 2026-09-25 after fixing the STATUS read (see below).
- **STATUS read fix (2026-09-25):** two root causes. (1) `conv_spi_ctrl.v` built the status byte with a Verilog `function` in a continuous assign; Icarus did not re-evaluate it when the derived `ready`/`locked` wires changed, so `tx_data` stayed stuck at a stale `READY|BUSY` (0x50) after `W_LOCK`. Replaced with a continuous-assign `wire [7:0] current_status`. (2) Protocol: a `STATUS` read needs a second (dummy) byte to clock the *fresh* status out — first MISO byte in the opcode window is the stale TX buffer. Documented in `SPI.md` + `quadbit_driver.status()`.
- **Async reset (2026-09-25):** `spi_slave`/`conv_spi_ctrl` SPI-domain registers now have a defined power-on state via async `sys_rst_n` (silicon FFs power up undefined).
- **Prior-art/patent sweep: COMPLETE (2026-09-27) — see `PRIOR_ART.md`.** Datapath/PE is well prior-arted (US20190102671, BinaryConnect, XNOR-Net, BittWare BWNN); **do not file a datapath patent.** What is ours: the SPI system protocol (incl. O_READ_BURST), host/chip split, and the ~$1 deterministic 1-bit edge niche. Name collision: QBit Semiconductor (Class 9) — formal trademark search required.

## Architecture (current)
- **Coprocessor = single convolution-layer accelerator.** 28×28×1 input → 26×26×16 output, 3×3 kernel, stride 1, zero-pad, ReLU.
- **The dense GEMM engine is reused as the MAC**, not rebuilt spatially (minimal area):
  - `quadbit_layer` K=9 (the 3×3 taps), N=16 (the filters).
  - `conv_ctrl` (spatial FSM) walks the 26×26 grid, feeds each 3×3 window as 9 taps (x_valid stream), and on completion writes the 16 ReLU'd outputs to `out_buf` (10,816 × 24-bit SRAM), then rearms the MAC for the next position.
  - `conv_window` + `frame_buf` generate window addresses (with edge zero-padding) combinationally.
- **Layer chaining = host model (single-layer accelerator).** Chip computes one full layer at max speed, independent of host read speed. Host (Raspberry Pi / the testbench) reads the feature map, does inter-layer glue (channel reduction + scale, zero-pad 26→28), then reprograms the chip and starts the next layer.
- **Reprogramming needs no new RTL:** `OP_RESET` pulses `soft_rst_n`; `quadbit_layer` reset returns it to `S_PROG` with weights/accs cleared, `frame_buf` re-arms, `conv_ctrl` → `S_IDLE`. Then the normal `W_WRITE`/`W_LOCK`/`F_WRITE`/`START` flow loads the next layer.
- Weight-lock model: weights programmed once per layer → LOCK → activations stream → read N sums. Anti-Von-Neumann.

## Locked decisions
- **Quadbit weight encoding (2 wires):** `10`=+1, `00`=0 (skip), `01`=-1, `11`=CTRL (0 + control flag, host-selectable semantics).
- **Datapath:** sign-select mux + negate. NO multiplier. Single-cycle (combinational PE).
- **Activation width:** 8-bit unsigned in (0..255).
- **Accumulator:** 24-bit signed, parameterized (ACC_W). Covers K up to ~4000, headroom for quantize.
- **Zero-skip:** native (w=00 contributes nothing, no bookkeeping).
- **Orchestrator:** host does ReLU glue / layer chaining / inter-layer scaling. Chip does conv math only. (On-chip ReLU of the layer output IS in `conv_ctrl` — output stored non-negative.)
- **Interface:** SPI mode 0, 4 wires + nREADY + nINT. Commands: RESET, W_WRITE, W_LOCK, START, O_READ, STATUS, F_WRITE (frame load — conv-specific, see `SPI.md`).
- **Reuse story:** same PE grid serves dense GEMM (K=784, N=512 MNIST path) and spatial conv (K=9, N=16 per tap); multi-pass CSD for >ternary precision = "generic GEMM" duality. (Note: per `PRIOR_ART.md` this is a reuse/engineering story, **not** a patent claim — the datapath is prior art.)
- **N_max 512 / K_max 784** remain the full-target parameters (CONFIRMED by John 2026-09-23); the conv instance simply instantiates the same engine at K=9, N=16.

## Inter-layer scaling (verified)
- `reduce(out1)`: per pixel, sum 16 channels → `>> 5` → clamp 255. (16ch → 1ch)
- `pad28`: 26×26 → 28×28 with 1-pixel zero border (feeds next layer's 3×3 window).
- **Why `>>5`:** with the test weights channel sums top out ~4050; `>>3` saturates (13 cells clamp, information lost), `>>6`+ collapses to <60 active cells (weak test). `>>5` → max 126, 96% non-zero, 27 distinct values, 2× margin to saturation. Sweep in `scaling_check.py`.
- `conv_ref.py` is the single source of truth; the testbench must reproduce `conv2d`/`reduce`/`pad28` exactly.

## Prior art (must distinguish)
- **XNOR-Net** (arXiv 1603.05279, Mar 2016) — binary conv net, multiply-by-sign. CONFIRMED published.
- Long line of ternary/1-bit quantization + signed-digit arithmetic.
- Patent likely hinges on the *combination*: 4-state 2-wire encoding w/ host-selectable 11-control + native zero-skip + weight-lock as a system. NOT the raw "+1/0/-1 weights" idea.
- Full prior-art sweep PENDING (Brave key now saved in `TOOLS.md`).

## Fab / process
- Target 130 nm, 150-200 MHz (conservative). **Fab SKIPPED** — John: a working sim is a valid patent "embodiment".
- Current conv instance area notes: `out_buf` (10,816 × 24-bit SRAM) is the dominant block; `frame_buf` (28×28×8) small; PE grid 9×16 trivial. Full MNIST target estimate unchanged: ~51 KB weight SRAM.

## Files
- `rtl/pe_quadbit.v` — PE core. SIM PASS + lint clean.
- `rtl/quadbit_layer.v` — K×N dense-layer engine (PE grid + accs + FSM + k_en/n_en + `rearm`). SIM PASS + lint clean. Reused as conv MAC.
- `rtl/spi_slave.v` — SPI mode-0 byte-framed transport. SIM PASS + lint clean.
- `rtl/conv_window.v` — 3×3 window address generator w/ edge zero-pad (combinational). SIM PASS + lint clean.
- `rtl/frame_buf.v` — 28×28×8 input-frame SRAM. SIM PASS + lint clean.
- `rtl/conv_ctrl.v` — spatial conv FSM (grid walk, tap stream, MAC rearm, ReLU, out_buf write). SIM PASS + lint clean.
- `rtl/conv_spi_ctrl.v` — conv SPI command FSM (RESET/W_WRITE/W_LOCK/F_WRITE/START/O_READ/STATUS). SIM PASS + lint clean.
- `rtl/out_buf.v` — 10,816 × 24-bit feature-map SRAM (autonomous operation; host reads at its own pace).
- `rtl/quadbit_conv_top.v` — convolution coprocessor top (SPI + frame/weight/out SRAMs + MAC + spatial FSM). SIM PASS + lint clean.
- `rtl/tb_*.v` — testbenches (pe, layer, spi_slave, conv_window, frame_buf, conv_top). All PASS.
- `conv_ref.py` — Python reference: `conv2d`, `reduce` (SHIFT=5), `pad28`; exports `frame1, w1, w2, out1, frame2, out2`. Side-effect-free import.
- `scaling_check.py` — inter-layer scaling regression (8 checks + shift sweep). ALL PASS.
- `SPI.md` — SPI command + protocol spec (opcodes, args, status byte, sequence; STATUS 2-byte read + CS# framing).
- `python/quadbit_spi.py` — fake-SPI bridge for cocotb (byte-framed `xfer`, MSB-first, mode 0).
- `python/quadbit_driver.py` — command-level driver: W_WRITE/W_LOCK/F_WRITE/START/O_READ/STATUS; `status()` = 2-byte read, returns fresh status (2nd byte); `wait_done()` polls BUSY.
- `python/tb_smoke.py` — cocotb bridge sanity test (Python↔Icarus VPI proven).
- `python/tb_conv_chain.py` — **2-layer chain test (PASS)**: `digits/digit0.txt` → layer 1 → STATUS poll → read 10,816 → `reduce(>>5)+pad28` → `OP_RESET` → layer 2 → verify all outputs vs `conv_ref.py`.
- `python/quadbit_digits.py` — 5 distinct deterministic 28×28 (0..255) test images (real MNIST digit0, bar, diagonal, ring, seeded noise). Pure Python, sim+Pi shared.
- `python/tb_conv_batch.py` — **5-image batch test (PASS 2026-09-25)**: full 2-layer chain for each of 5 distinct images + **explicit reset assertions** (after RESET → READY+BUSY set/no ERROR; after LOCK → LOCKED/no ERROR; after RUN → no ERROR). All 5 × 21,632 outputs match `conv_ref.py` exactly. Proves reset + multi-image reuse.
- `python/digits/digit0.txt` — real MNIST digit test input (28×28, 0..255).
- `AREA_TIMING_130NM.md` — **130 nm area/timing sanity check (2026-09-25)**: ~25 mm² realistic / ~48 mm² worst-case; ~100–200 MHz; ~0.2 ms/conv. Memory-bound — 32 KB `out_buf` is ~90% of die. **`ACC_W` kept at 24** (John: engine must stay general for other models) — the 24→13 area lever is therefore *not* applied.

> Legacy dense-flow files (`quadbit_top.v`, `spi_ctrl.v`, `tb_quadbit_top.v`, `tb_spi_bridge.v`, `sim_spi_bridge.cpp`, `test_quadbit.py`, `spi_ctrl_part2_draft.v`) were removed from the tree 2026-09-24; recoverable from git history (pre-`<housekeeping-commit>`).

## Next steps
1. DONE (2026-09-25): **2-layer chain testbench in Python/cocotb** — `python/tb_conv_chain.py` PASSES: all 10,816 + 10,816 outputs match `conv_ref.py` exactly (out1 sum 290774, out2 sum 140699). Required the STATUS 2-byte protocol + `current_status` wire fix (see Status).
2. **Retry prior-art search** (Brave API key available) — still pending.
3. DONE (2026-09-25): **130 nm area/timing sanity check** — `AREA_TIMING_130NM.md`. ~25 mm² realistic (SRAM buffers) / ~48 mm² worst-case (all-FF); ~100–200 MHz (24-bit acc adder is the ~70-level critical path); ~0.2 ms/conv @100 MHz. Verdict: feasible at 130 nm, memory-bound. Fab remains skipped. **`ACC_W` intentionally kept at 24** (general engine for other models) — the 24→13 area lever is documented but not applied.
4. DONE (2026-09-25): **5-image batch test** — `python/tb_conv_batch.py` PASSES (all 5 × 21,632 outputs match; reset asserted between every image/layer). Proves the chip resets and runs >1 image.
5. DONE (2026-09-24): housekeeping — legacy dense cluster + draft + build artifacts removed (in git history); `results.xml` added to `.gitignore`.

## Build notes / iverilog + verilator quirks
- `9'sd-255` is invalid → use `-9'sd255`.
- Avoid SystemVerilog size casts `W'(x)`; avoid `reg` arrays driven by continuous assign (use `wire`).
- `vvp` can hang on `task`s with `output` port args of the wrong shape — single-word output args work (used in the conv TB); if a TB hangs at a task call, inline the reads.
- Verilator: intentional behaviors need `/* verilator lint_off <WARN> */` (e.g. `BLKSEQ` for memory-init-in-reset, `PINCONNECTEMPTY` for deliberately unconnected ports, `UNUSEDSIGNAL`/`UNUSEDPARAM` for spec'd-but-unused wires).
- `conv_ctrl` bug history (fixed, documented in commits): blanket `ob_we <= 0` default dropped the write-enable after 1 cycle (only `mem[0]` written); tap stream was off-by-one vs. combinational `frame_buf`/`conv_window` (first tap lost). Both fixed; `S_READOUT` now holds `ob_we` across the 16-filter window.
