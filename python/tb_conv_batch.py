"""tb_conv_batch.py — 5-image batch test: proves the chip RESETS between images.

For EACH of 5 distinct 28x28 images (quadbit_digits.make_images) it runs the
full two-layer chain exactly as on the single-image chain test, and adds
EXPLICIT reset assertions the chain test never checked:

  after RESET  -> status must show READY (engine back in S_PROG) AND BUSY
                  (done-latch cleared: busy = !conv_done) AND no ERROR
  after LOCK   -> status must show LOCKED, no ERROR
  after RUN    -> BUSY cleared, no ERROR
  outputs      -> all 10,816 out1 + 10,816 out2 match conv_ref.py exactly

Because the 5 images are DISTINCT, any reset failure (stale frame_buf pixels
or un-cleared accumulators leaking from image N into image N+1) would corrupt
image N+1's outputs and fail the compare. Passing all 5 is therefore a direct
proof the chip resets and re-runs — not just that one image worked.

Transport-agnostic (sim + Pi): uses only QuadbitConv + spidev-compatible
xfer().  Sim invocation identical to tb_conv_chain (COCONV_TEST_MODULES=tb_conv_batch).
"""

import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)                                   # quadbit_spi/driver/digits
sys.path.insert(0, os.path.dirname(_HERE))                  # conv_ref

from quadbit_spi import QuadbitSpi                          # noqa: E402
from quadbit_driver import (QuadbitConv, ST_READY, ST_LOCKED,  # noqa: E402
                            ST_BUSY, ST_ERROR)
import conv_ref as R                                        # noqa: E402
from quadbit_digits import make_images, ink, NAMES          # noqa: E402


# ---- helpers (self-contained; same definitions as tb_conv_chain) ----------

def reshape(flat):
    """flat[10816] -> [r][c][f], chip order v = r*26*16 + c*16 + f."""
    out = [[[0] * R.N for _ in range(R.OUT)] for _ in range(R.OUT)]
    for r in range(R.OUT):
        for c in range(R.OUT):
            base = r * R.OUT * R.N + c * R.N
            for f in range(R.N):
                out[r][c][f] = flat[base + f]
    return out


def compare(sim_grid, ref_grid):
    mismatches = []
    for r in range(R.OUT):
        for c in range(R.OUT):
            for f in range(R.N):
                if sim_grid[r][c][f] != ref_grid[r][c][f]:
                    mismatches.append((r, c, f, sim_grid[r][c][f],
                                       ref_grid[r][c][f]))
    return mismatches


async def monitor(dut):
    prev_st = None
    while True:
        await RisingEdge(dut.sys_clk)
        try:
            st = dut.u_layer.st.value.to_unsigned()
        except Exception:
            st = -1
        if st != prev_st:
            dut._log.info(f"MONITOR Time {cocotb.utils.get_sim_time('ns')}ns: "
                          f"LAYER ST {prev_st} -> {st}")
            prev_st = st


# ---- per-image driver with explicit reset assertions ----------------------

async def run_image(qb, digit, tick, img_name):
    """Run the full 2-layer chain for one image; assert reset at each stage."""
    log = cocotb.log

    # ---------------- reference (pure Python, single source of truth) ------
    ref_out1 = R.conv2d(digit, R.w1)
    ref_frame2 = R.pad28(R.reduce(ref_out1))
    ref_out2 = R.conv2d(ref_frame2, R.w2)
    ref_sum1 = sum(v for row in ref_out1 for px in row for v in px)
    ref_sum2 = sum(v for row in ref_out2 for px in row for v in px)

    # ============================ Layer 1 ==================================
    await qb.reset()
    st = await qb.status()
    assert st & ST_READY, \
        f"{img_name}: after RESET, READY expected (S_PROG); status=0x{st:02x}"
    assert st & ST_BUSY, \
        f"{img_name}: after RESET, BUSY expected (done-latch cleared); " \
        f"status=0x{st:02x}"
    assert not (st & ST_ERROR), \
        f"{img_name}: after RESET, ERROR set; status=0x{st:02x}"

    await qb.program_weights(R.w1)          # W_WRITE x144 + W_LOCK
    st = await qb.status()
    assert st & ST_LOCKED, \
        f"{img_name}: after LOCK, LOCKED expected; status=0x{st:02x}"
    assert not (st & ST_ERROR), \
        f"{img_name}: after LOCK, ERROR set; status=0x{st:02x}"

    await qb.program_frame(digit)           # F_WRITE x784
    await qb.start()
    st = await qb.wait_done(tick=tick)
    assert not (st & ST_ERROR), f"{img_name}: L1 run ERROR; status=0x{st:02x}"
    sim1_flat = await qb.read_outputs()
    sim_frame2 = R.pad28(R.reduce(reshape(sim1_flat)))

    # ============================ Layer 2 ==================================
    # reset between layers exercises the SAME soft-reset path as between
    # images — this is the path that must clear layer/frame/conv_ctrl state.
    await qb.reset()
    st = await qb.status()
    assert st & ST_READY, \
        f"{img_name}: L2 after RESET, READY expected; status=0x{st:02x}"
    assert st & ST_BUSY, \
        f"{img_name}: L2 after RESET, BUSY expected; status=0x{st:02x}"
    assert not (st & ST_ERROR), \
        f"{img_name}: L2 after RESET, ERROR set; status=0x{st:02x}"

    await qb.program_weights(R.w2)
    st = await qb.status()
    assert st & ST_LOCKED, \
        f"{img_name}: L2 after LOCK, LOCKED expected; status=0x{st:02x}"
    assert not (st & ST_ERROR), \
        f"{img_name}: L2 after LOCK, ERROR set; status=0x{st:02x}"

    await qb.program_frame(sim_frame2)
    await qb.start()
    st = await qb.wait_done(tick=tick)
    assert not (st & ST_ERROR), f"{img_name}: L2 run ERROR; status=0x{st:02x}"
    sim2_flat = await qb.read_outputs()

    # ============================ verify ===================================
    sim1 = reshape(sim1_flat)
    sim2 = reshape(sim2_flat)
    sim_sum1 = sum(sim1_flat)
    sim_sum2 = sum(sim2_flat)
    log.info("[%s] ref:  out1 sum=%d  out2 sum=%d", img_name, ref_sum1, ref_sum2)
    log.info("[%s] chip: out1 sum=%d  out2 sum=%d", img_name, sim_sum1, sim_sum2)

    m1 = compare(sim1, ref_out1)
    m2 = compare(sim2, ref_out2)
    if m1 or m2:
        for name, m, ref in (("out1", m1, ref_out1), ("out2", m2, ref_out2)):
            if not m:
                continue
            log.error("[%s] %s: %d/%d mismatches; first: %s",
                      img_name, name, len(m), R.OUT_TOTAL, m[0])
            for (r, c, f, s, e) in m[:8]:
                log.error("  [%d,%d,%d] sim=%d ref=%d", r, c, f, s, e)
        raise AssertionError(
            f"{img_name}: {len(m1)} out1 + {len(m2)} out2 mismatches")

    log.info("[%s] PASS — %d + %d outputs match reference exactly",
             img_name, R.OUT_TOTAL, R.OUT_TOTAL)
    return sim_sum1, sim_sum2


@cocotb.test()
async def conv_batch(dut):
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

    images = make_images()
    log.info("=== BATCH TEST: %d distinct images, full 2-layer chain each ===",
             len(images))
    for i, img in enumerate(images):
        log.info("=== IMAGE %d/%d: %s (ink=%d px) ===",
                 i + 1, len(images), NAMES[i], ink(img))

    for i, img in enumerate(images):
        await run_image(qb, img, tick, f"img{i}")
        log.info("=== IMAGE %d/%d COMPLETE ===", i + 1, len(images))

    log.info("=== CONV BATCH PASS: %d images, each 2-layer chain matched "
             "reference exactly; reset verified between every image/layer ===",
             len(images))
