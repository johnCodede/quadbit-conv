# Pi-native vs Coprocessor — Timing Estimate (2-layer quadbit net)

Date: 2026-09-27 · Author: Jeff (AI)
Question (John): *timing estimate between a Raspberry Pi running MNIST natively
and the coprocessor running with it.*

**Status: O_READ burst mode (`0x09`) is implemented and is the default
readout.** All coprocessor numbers below are post-burst.

## Net under comparison (identical on both paths)

28×28 single-channel in → conv 3×3 ×16 filters (zero-pad, ReLU) → host
reduce (>>5, clamp 255) + pad28 → conv 3×3 ×16 → 26×26×16 out.
~216k MACs/image. Weights: quadbit 2-bit (144 slots/layer).

## Three different "times" — don't conflate them

This is the #1 source of confusion, so it's called out first. For the same
5-image batch test there are three numbers:

| Time | Value (per image) | What it is |
|---|---|---|
| **Wall / host time** | **58.9 s** | Python bit-bang driver + Icarus Verilog stepping every SPI bit. *Emulation overhead, not chip speed.* |
| **Sim / chip time** | **35.6 ms** | How long the RTL actually ran at `sys_clk = 100 MHz`. *This is the number real hardware reproduces.* |
| **FPGA (real)** | **≤ 35.6 ms** (faster if sclk > 16.7 MHz) | Real silicon at the same or higher SPI clock. |

Wall/sim ratio ≈ **1650×**. That gap is pure software-emulation cost
(a Python event per SPI bit + a discrete-event sim step per cycle). It
vanishes entirely on real hardware — the FPGA runs at sim-time speed.

## Measured numbers (post-burst, 2026-09-27)

| Path | Per image | Source |
|---|---|---|
| **x86, pure Python (native), 5-image median** | **19.1 ms** | `python/bench_native.py` |
| **Pi 4 (A72), pure Python (native)** | **~30–60 ms** | x86 × 1.5–3 (CPython single-core scaling, assumption) |
| **Pi 4, TFLite Micro / int8 (native, optimized)** | **~1–3 ms** | published-range estimate (C+NEON, not measured) |
| **Coprocessor engine compute only** | **~0.4 ms** | 2 × 18.9k cycles @100 MHz (`AREA_TIMING_130NM.md`) |
| **Coprocessor, sim, Python bit-bang (eff. 16.7 MHz sclk)** | **35.6 ms** | `tb_conv_batch` measured: 177.76 ms / 5 images |
| **Coprocessor, FPGA, 25 MHz sclk (byte floor)** | **~23.3 ms** | 72,920 bytes × 8 / 25 MHz |
| **Coprocessor, FPGA, 50 MHz sclk (byte floor)** | **~11.7 ms** | 72,920 bytes × 8 / 50 MHz |

## Cycle-accurate per-image budget (post-burst)

Derived from the exact command frames in `quadbit_driver.py`, one 2-layer
chain per image (layer 1 + layer 2, each with its own program/run/readout):

| Command | Transactions | Bytes | Notes |
|---|---:|---:|---|
| RESET | 2 | 2 | 1 per layer |
| W_WRITE | 288 | 1,728 | 144/layer × 6 bytes |
| W_LOCK | 2 | 2 | 1 per layer |
| STATUS | ~8 | ~16 | after reset/lock + done-polls (variable) |
| F_WRITE | 1,568 | 6,272 | 784/layer × 4 bytes |
| START | 2 | 2 | 1 per layer |
| **O_READ_BURST** | **2** | **64,906** | 1/layer: 5-byte cmd + 10,816 × 3 data |
| **Total** | **~1,872** | **~72,928** | |

The burst readout is **89% of all bytes** (64,906 / 72,928) but only **2 of
~1,872 transactions**. That is the whole point of burst: the byte count
(which sets the sclk floor) is unchanged, but the per-transaction CS
overhead collapses from 10,816 reads/layer to 1.

### sclk floor (pure bit time, per image)

`72,928 bytes × 8 bits ≈ 583,400 bits`

| sclk | Bit time / image |
|---|---|
| **16.7 MHz** (sim's effective rate) | **35.0 ms** |
| 25 MHz | 23.3 ms |
| 50 MHz | 11.7 ms |
| 100 MHz | 5.8 ms |

The sim's measured **35.6 ms/image** is 99% of the 16.7 MHz bit-time floor
(35.0 ms); the remaining ~0.6 ms is per-transaction CS overhead plus engine
run time. In other words, **the sim measurement ≈ the sclk floor at the sim's
effective clock rate** — and a real FPGA SPI peripheral running faster than
16.7 MHz beats it.

### Why the sim's effective sclk is 16.7 MHz, not 25 MHz

`quadbit_spi.py` bit-bangs each bit with three 20 ns settles
(`half_ns=20`) → **60 ns/bit** → 16.7 MHz effective. A real SPI peripheral
clocks a bit in one sclk period, so 25 MHz is a true 25 MHz.

## Burst before / after (the change that mattered)

| Metric | Pre-burst (`O_READ`) | Post-burst (`O_READ_BURST`) | Change |
|---|---|---|---|
| Transactions / image | ~23.5k | ~1.9k | **12× fewer** |
| Bytes / image | ~137.8k | ~72.9k | **1.9× fewer** (3 addr/dummy bytes/word removed) |
| Sim time / image | **68.43 ms** | **35.55 ms** | **1.9× faster** |
| Wall time / 5 images | **570.4 s** | **294.4 s** | **1.9× faster** |

Pre-burst measurement: `tb_conv_chain` 68.43 ms/image; 5-image batch
342.1 ms sim / 570.4 s wall. Post-burst: 177.76 ms sim / 294.4 s wall. Both
runs PASS all 5 images vs `conv_ref.py`.

Non-burst clocked 6 bytes per output word (3 data + 3 address/dummy), so
half the readout bit stream was overhead. Burst amortizes the address over
all 10,816 words and collapses the CS transactions. Both effects cut the
sim time and the real-Pi spidev overhead by ~1.9×.

## Verdict (post-burst)

- **On single-image latency for this small net, Pi-native is competitive or
  faster.** TFLite Micro (~1–3 ms) beats the coprocessor's SPI path
  (~23 ms @25 MHz). Pure-Python native (~30–60 ms on the Pi) is roughly a
  tie with the coprocessor @25 MHz.
- **The coprocessor's value is not raw speed for this workload.** The engine
  computes both convolutions in ~0.4 ms; the rest of the latency is the SPI
  byte stream. Burst mode removed the per-transaction CS overhead that
  dominated the old protocol.
- **The coprocessor wins on:**
  1. **Concurrency** — the A72 is free to do other work while the chip convolves.
  2. **Energy** — ~0.4 ms of gate activity vs 30–60 ms of full-core activity.
  3. **Deterministic latency** — fixed cycle count, no scheduler noise.
  4. **Weight encoding** — the quadbit 2-bit add/subtract datapath; area/energy *per weight*.

## How to reproduce

```
cd projects/quadbit/python
python3 bench_native.py --runs 5            # native baseline (any machine, incl. the Pi)
# coprocessor sim (burst):
COCONV_TEST_MODULES=tb_conv_batch <your cocotb runner>
```
Pi: the same `QuadbitConv` driver over `spidev` (it uses the spidev-compatible
`.xfer()` API).
