"""tb_conv_chain.py — two-layer conv chain test for the quadbit coprocessor.

Runs a real MNIST digit (t10k[0]) through both layers of the reference
chain, exactly as the host would drive the chip over SPI:

  Layer 1:  RESET -> W_WRITE(w1) x144 -> W_LOCK -> F_WRITE(digit) x784 -> START
            -> poll STATUS until BUSY clears -> O_READ x10,816
  Host:     reduce(>>5) + pad28          (conv_ref.reduce / conv_ref.pad28)
  Layer 2:  RESET -> W_WRITE(w2) x144 -> W_LOCK -> F_WRITE(frame2) x784 -> START
            -> poll STATUS until BUSY clears -> O_READ x10,816

Verification: full element-wise match (10,816 x 2 layers) of the chip's
outputs against the pure-Python reference in conv_ref.py (single source
of truth).

The test body is transport-agnostic: it only uses QuadbitConv + the
spidev-compatible xfer() API, so the same file runs on the Pi with
`spi = spidev.SPIDevice(0, 0)` and `asyncio.run(...)`.

Sim invocation (Icarus + cocotb 2.1.0):
  iverilog -o sim.vvp -s quadbit_conv_top timescale_shim.v <rtl files>
  vvp -n -M <vpi-dir> -m libcocotbvpi_icarus sim.vvp
  (COCOTB_TEST_MODULES=tb_conv_chain, TOPLEVEL=quadbit_conv_top, ...)
"""

import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)                                   # quadbit_spi/driver
sys.path.insert(0, os.path.dirname(_HERE))                  # conv_ref

from quadbit_spi import QuadbitSpi                          # noqa: E402
from quadbit_driver import QuadbitConv, ST_READY, ST_LOCKED, ST_ERROR  # noqa: E402
import conv_ref as R                                        # noqa: E402

DIGIT_FILE = os.path.join(_HERE, "digits", "digit0.txt")


def load_digit():
    """28x28 0..255 from digits/digit0.txt, fallback to conv_ref ramp."""
    if os.path.exists(DIGIT_FILE):
        grid = []
        with open(DIGIT_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                grid.append([int(x) for x in line.split()])
        assert len(grid) == 28 and all(len(row) == 28 for row in grid), \
            "digit file must be 28x28"
        return grid
    return R.frame1


def reshape(flat):
    """flat[10816] -> [r][c][f], index v = r*26*16 + c*16 + f (chip order)."""
    out = [[[0] * R.N for _ in range(R.OUT)] for _ in range(R.OUT)]
    for r in range(R.OUT):
        for c in range(R.OUT):
            base = r * R.OUT * R.N + c * R.N
            for f in range(R.N):
                out[r][c][f] = flat[base + f]
    return out


def compare(name, sim_grid, ref_grid):
    mismatches = []
    for r in range(R.OUT):
        for c in range(R.OUT):
            for f in range(R.N):
                s, e = sim_grid[r][c][f], ref_grid[r][c][f]
                if s != e:
                    mismatches.append((r, c, f, s, e))
    return mismatches


from cocotb.triggers import RisingEdge
async def monitor(dut):
    prev_st = None
    while True:
        await RisingEdge(dut.sys_clk)
        try:
            st = dut.u_layer.st.value.to_unsigned()
        except Exception:
            st = -1
        if st != prev_st:
            dut._log.info(f"MONITOR Time {cocotb.utils.get_sim_time('ns')}ns: LAYER ST CHANGED {prev_st} -> {st}")
            prev_st = st

@cocotb.test()
async def conv_chain(dut):
    log = cocotb.log

    # ---- power-on (sim) / assumed done by hardware (Pi) --------------------
    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())
    cocotb.start_soon(monitor(dut))
    dut.sys_rst_n.value = 0
    dut.spi_sclk.value = 0
    dut.spi_cs_n.value = 1
    dut.spi_mosi.value = 0
    await Timer(100, unit="ns")
    dut.sys_rst_n.value = 1
    await Timer(100, unit="ns")

    spi = QuadbitSpi(dut)          # Pi: spidev.SPIDevice(0, 0)
    qb = QuadbitConv(spi)
    tick = lambda: Timer(10_000, unit="ns")   # poll interval in sim time
    # Pi: tick = lambda: asyncio.sleep(0.001)

    digit = load_digit()
    ink = sum(1 for row in digit for v in row if v > 32)
    log.info("input: %s (ink=%d px)", DIGIT_FILE if os.path.exists(DIGIT_FILE)
             else "conv_ref ramp fallback", ink)

    # ---- reference chain (pure Python, single source of truth) ------------
    ref_out1 = R.conv2d(digit, R.w1)
    ref_frame2 = R.pad28(R.reduce(ref_out1))
    ref_out2 = R.conv2d(ref_frame2, R.w2)
    ref_sum1 = sum(ref_out1[r][c][f] for r in range(R.OUT) for c in range(R.OUT) for f in range(R.N))
    ref_sum2 = sum(ref_out2[r][c][f] for r in range(R.OUT) for c in range(R.OUT) for f in range(R.N))
    log.info("reference: out1 sum=%d  out2 sum=%d", ref_sum1, ref_sum2)

    # ============================ Layer 1 ==================================
    log.info("--- layer 1: program w1 (%d weights)", len(R.w1) * R.N)
    await qb.reset()
    await qb.program_weights(R.w1)          # W_WRITE x144 + W_LOCK
    await qb.program_frame(digit)           # F_WRITE x784

    st = await qb.status()
    # assert st & ST_READY  # READY and LOCKED are mutually exclusive
    assert st & ST_LOCKED, f"LOCKED expected before START, status=0x{st:02x}"
    assert not (st & ST_ERROR), f"ERROR bit set before START: 0x{st:02x}"

    log.info("--- layer 1: START")
    await qb.start()
    st = await qb.wait_done(tick=tick)
    assert not (st & ST_ERROR), f"ERROR after run: 0x{st:02x}"
    log.info("--- layer 1: read %d outputs", qb.OUT_TOTAL)
    sim1_flat = await qb.read_outputs()

    # ======================= host glue (inter-layer) ========================
    sim_frame2 = R.pad28(R.reduce(reshape(sim1_flat)))

    # ============================ Layer 2 ==================================
    log.info("--- layer 2: reset + program w2")
    await qb.reset()                        # OP_RESET -> S_PROG again
    await qb.program_weights(R.w2)
    await qb.program_frame(sim_frame2)
    await qb.start()
    st = await qb.wait_done(tick=tick)
    assert not (st & ST_ERROR), f"ERROR after run: 0x{st:02x}"
    log.info("--- layer 2: read %d outputs", qb.OUT_TOTAL)
    sim2_flat = await qb.read_outputs()

    # ============================ verify ===================================
    sim1 = reshape(sim1_flat)
    sim2 = reshape(sim2_flat)
    sim_sum1 = sum(sim1_flat)
    sim_sum2 = sum(sim2_flat)
    log.info("chip:      out1 sum=%d  out2 sum=%d", sim_sum1, sim_sum2)

    m1 = compare("out1", sim1, ref_out1)
    m2 = compare("out2", sim2, ref_out2)

    if m1 or m2:
        for name, m, ref in (("out1", m1, ref_out1), ("out2", m2, ref_out2)):
            if not m:
                continue
            log.error("%s: %d/%d mismatches; first: %s",
                      name, len(m), R.OUT_TOTAL, m[0])
            for (r, c, f, s, e) in m[:8]:
                log.error("  [%d,%d,%d] sim=%d ref=%d", r, c, f, s, e)
        assert not (m1 or m2), f"{len(m1)} out1 + {len(m2)} out2 mismatches"

    log.info("out1[0,0,0]=%d out1[25,25,15]=%d out2[25,25,15]=%d",
             sim1[0][0][0], sim1[25][25][15], sim2[25][25][15])
    log.info("=== CONV CHAIN PASS: %d + %d outputs match reference exactly ===",
             R.OUT_TOTAL, R.OUT_TOTAL)
