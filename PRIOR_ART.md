# Quadbit Conv Coprocessor — Prior-Art / Patent Sweep

Date: 2026-09-27 · Author: Jeff (AI) · Status: **sweep complete**

Scope: the four load-bearing ideas in `rtl/`, checked against published
literature, products, and patent filings.

## 0. Bottom line

**The PE core is NOT patentable — the datapath is well prior-arted.**
The "weights ∈ {±1,0} so multiply becomes a sign-select add" trick is the
established foundation of the entire binary/ternary neural network (BNN/TNN)
literature (2015→present) and is already disclosed in at least one directly
relevant US patent application (US20190102671, "shared adder tree… selected
from {−1,0,+1}… with a simple multiplexer"). The specific 2-bit ternary
encoding `{10:+1, 01:−1, 00:0}` and the sign-select/negate-accumulate PE are
textbook techniques, not a novel primitive. The "11 = control" 4th state is a
thin twist on a "don't-care/reserved" code that standard ternary hardware
already reserves.

**Do NOT file a datapath patent.** It would be weak, expensive, and likely
obvious in view of BinaryConnect (2015), XNOR-Net (2016), BittWare BWNN,
TileNET (2021), xTern (2024), and US20190102671.

What IS ours (defensible but thin): the **system** — the SPI coprocessor
protocol, the O_READ_BURST (0x09) readout, the host/chip division of labor,
and the **niche** (tiny, cheap, deterministic, Pi-attached, 1-bit-weight).
That is a *commercial position*, not strong IP. If any filing is made, it
must be framed as a system claim with US20190102671 in hand, and only after
a real patent attorney reviews it.

**Name risk:** "QBit Semiconductor" (active, Taiwan, ex-Qualcomm imaging) is
phonetically near "Quadbit" in Class 9 (semiconductors). Formal USPTO/EUIPO
Class 9 trademark search required before any commercial branding.

---

## 1. PE core / datapath — PRIOR ART (not novel)

### 1.1 Binary/ternary weights → multiply-free MAC

- **BinaryConnect** (Courbariaux, Bengio, Vincent, 2015) — weights ∈ {−1,+1};
  multiplication removed. arXiv:1511.00363.
- **XNOR-Net** (Rastegari et al., 2016) — "can the product of two binary
  values be computed without a [multiplier]?" → popcount + sign. arXiv:1603.05279.
- **BittWare BWNN** (product) — "weights are binarized with only two values:
  +1 and -1… reduces all fixed-point multiplication operations in the
  convolutional layers… to integer additions." → **exactly our `pe_quadbit`.**
- **xTern** (2024) — "Ternary weights avoid multiplications, requiring only
  additions and subtractions."
- **TWIN** (2026, arXiv:2601.16002) — "weights in {-1,0,1}… each
  multiplication becomes an addition."
- **DSNN ternary** (2022, arXiv:2203.13433) — ternary weights, "avoiding
  multiplications and using simple addition and subtraction."

### 1.2 Sign-select / negate-and-add PE

- **US20190102671A1 — Inner Product Convolutional Neural Network Accelerator.**
  Closest patent hit. Discloses: "a binary neural network (BNN) and a ternary
  neural network (TNN) can both **share a common adder tree**. The sum of
  products for a TNN is **selected from {−1, 0, +1}… with a simple multiplexer
  being provided**." → Our sign-select mux + shared accumulator.
- **US20190251425A1 — BNN Accelerator Engine.** Popcount-based; "BNN
  multipliers may be eliminated."
- **US20180046906A1 — Sparse Convolutional Neural Network Accelerator.** Binary
  weights.
- **CA3069779C — Neural network processing element.** Weight/activation lanes
  into a PE.
- **KR102540226B1 — Ternary Neural Network Accelerator.**
- **IEEE 8350945 — A Convolutional Accelerator for Neural Networks With Binary
  Weights.**

### 1.3 2-bit ternary weight encoding

- **arXiv:1707.03684 — Structured Sparse Ternary Weight Coding for Efficient
  Hardware Implementations.** "the precision of the weight can be lowered to
  **2-bit** (+1, 0 and -1)… can avoid multiplications."
- **Sparsity-control ternary weight networks** (Neural Networks, 2021):
  "training ternary weight {−1, 0, +1} networks which can avoid
  multiplications."
- Our `{10:+1, 00:0, 01:−1, 11:ctrl}` uses a 4th "control" code that standard
  ternary hardware reserves/don't-cares. Thin distinction; not separately
  patentable.

### 1.4 BNN/TNN accelerator hardware (crowded)

- **XNORBIN** (2018): 0.54 mm², 95 TOp/s/W binary CNN accelerator.
- **XNOR Neural Engine** (2028-era, 2018): 21.6 fJ/op, MCU-integrated.
- **Binary Precision Neural Network Manycore Accelerator** (ACM, 2020).
- **TileNET** (2021): ternary, 16×16, 1.2 mm².
- **xTern** (2024), **TWIN** (2026) — ternary accelerators.
- **QBit Semiconductor** (product/company) — imaging SoC, not BNN; name
  collision only.

## 2. Coprocessor / SPI offload — KNOWN PATTERN

- **NPU_X_Interface** (2026): "NPU coprocessor extends a RISC-V core…
  enabling the host processor to **offload convolution operations** to
  dedicated hardware."
- **Espressif esp_hosted / esp-hosted-mcu** (2024): "The host keeps the
  product logic. The ESP co-processor offloads the radio and network stack
  over your chosen transport bus [SDIO, SPI, UART]."
- Offloading a compute function to an SPI-attached coprocessor is a known
  architecture (radio, GPU, NPU, FPGA). **Not novel by itself.**

## 3. What IS ours (thin, system-level)

1. **The exact SPI protocol** — byte-framed opcodes,
   `W_WRITE → W_LOCK → F_WRITE → START` ordering, and
   **O_READ_BURST (0x09)** collapsing ~23.5k transactions to ~1.9k. The
   burst-readout + host-does-reduce/pad split is not a direct prior-art hit.
2. **The host/chip division of labor** — chip does one fixed-shape conv layer;
   host does the `>>5`/clamp/pad glue between layers. Specific, but narrow.
3. **The niche** — ~$1 die, deterministic, Pi-attached, 1-bit-weight
   MNIST-class inference. A market position, not a patent.

These are **system-level claims at best** — thinner than a datapath patent
and closer to engineering than invention, which limits enforceability.

## 4. Name / trademark

- **QBit Semiconductor** (Taiwan, 2016, ex-Qualcomm) — active, Class 9.
  Phonetically near "Quadbit." Formal USPTO/EUIPO Class 9 search required
  before any commercial branding; budget for a rename if the collision is live.
- `"Quadbit"` + AI/chip/accelerator returned **zero** direct hits — no obvious
  AI-chip "Quadbit" squaring off, but the QBit collision is real.

## 5. Recommendation

1. **Do not file a datapath patent.** US20190102671 + BinaryConnect/XNOR-Net/
   BittWare make "multiply-free 1-bit/ternary conv" obvious.
2. **If any IP is desired**, frame it as the *system* (SPI protocol + burst
   readout + host/chip split) and review with a real patent attorney,
   US20190102671 in hand, before spending money.
3. **Sort out the name** before attaching it to anything commercial.
4. **Position commercially on the niche, not the primitive** — "a ~$1
   deterministic conv coprocessor for 1-bit edge models." True and defensible;
   do not claim the multiply trick as novel, because it isn't.

---

*Method: web_search (Brave) across IEEE Xplore, arXiv, Semantic Scholar,
  patents.google.com, and product/academic sites, 2026-09-27. This is an
  **estimate/sweep, not a legal opinion**. For enforceability, engage a
  licensed patent attorney and a trademark attorney; a full novelty search
  (esp. US20190102671 and the BittWare/BNN patent family) is required before
  any filing or public commercial claim.*
