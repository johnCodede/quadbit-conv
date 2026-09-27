"""quadbit_driver.py — pure-Python command layer for the quadbit conv coprocessor.

Runs UNCHANGED on both targets:
  * simulation:  spi = quadbit_spi.QuadbitSpi(dut)          (async .xfer)
  * Raspberry Pi: spi = spidev.SPIDevice(0, 0)              (sync .xfer)

Every command is one CS transaction (SPI mode 0, MSB first). Byte layouts
per SPI.md:

  RESET    0x01        1 byte
  W_WRITE  0x02        op, k_hi, k_lo, n_hi, n_lo, val      (6 bytes)
  W_LOCK   0x03        1 byte
  START    0x04        1 byte
  O_READ   0x06        op, addr_hi, addr_lo, d, d, d        (6 bytes)
                response = last 3 bytes: acc[23:16] acc[15:8] acc[7:0]
  STATUS   0x07        1 byte -> status
  F_WRITE  0x08        op, row, col, val                    (4 bytes)

STATUS bits (conv_spi_ctrl.build_status):
  bit 7  ERROR (latched error, ec != 0)
  bit 6  READY (engine in S_PROG)
  bit 5  LOCKED (weights locked)
  bit 4  BUSY  (sticky level: 1 until the run's done-latch sets; clears on done)
  bits 3:0  error code
  Done is indicated by BUSY clearing (done is latched in RTL, cleared by START/RESET).

Weight encoding `val` (quadbit): 0 = zero/skip, 1 = -1, 2 = +1, 3 = ctrl.
Frame values: 0..255.
Output values: 24-bit unsigned post-ReLU (0..2^24-1).
"""

import asyncio
import time

OP_RESET    = 0x01
OP_W_WRITE  = 0x02
OP_W_LOCK   = 0x03
OP_START    = 0x04
OP_O_READ   = 0x06
OP_O_READ_BURST = 0x09
OP_STATUS   = 0x07
OP_F_WRITE  = 0x08

ST_ERROR = 0x80
ST_READY = 0x40
ST_LOCKED = 0x20
ST_BUSY  = 0x10
ST_ERRCODE_MASK = 0x0F


def _xfer(spi, tx):
    """Call spi.xfer synchronously or as a coroutine (works for spidev and sim)."""
    rx = spi.xfer(tx)
    if hasattr(rx, "__await__"):
        return rx
    return rx


async def _await(x):
    if hasattr(x, "__await__"):
        return await x
    return x


class QuadbitConv:
    """Command-level driver. One instance per SPI device."""

    K = 9        # kernel taps (3x3)
    N = 16       # filters
    FRAME = 28   # spatial size (28x28)
    OUT_PER_FILTER = 26 * 26
    OUT_TOTAL = N * OUT_PER_FILTER

    def __init__(self, spi):
        self.spi = spi

    # -- single-transaction primitives (async wrappers) ---------------------

    async def _x(self, tx):
        return await _await(_xfer(self.spi, tx))

    # -- command API ---------------------------------------------------------

    async def reset(self):
        await self._x([OP_RESET])

    async def write_weight(self, k, n, val):
        """Program one quadbit weight. k: 0..8, n: 0..15, val: 0/1/2/3."""
        k &= 0xFFFF
        n &= 0xFFFF
        await self._x([OP_W_WRITE, (k >> 8) & 0xFF, k & 0xFF,
                       (n >> 8) & 0xFF, n & 0xFF, val & 0xFF])

    async def lock(self):
        await self._x([OP_W_LOCK])

    async def write_frame(self, row, col, val):
        """Program one frame pixel. row/col: 0..27, val: 0..255."""
        await self._x([OP_F_WRITE, row & 0xFF, col & 0xFF, val & 0xFF])

    async def start(self):
        """Kick off the convolution run."""
        await self._x([OP_START])

    async def status(self):
        return (await self._x([OP_STATUS, OP_STATUS]))[1]

    async def is_busy(self):
        return bool((await self.status()) & ST_BUSY)

    async def is_done(self):
        """Done = BUSY cleared (the done flag is latched in RTL)."""
        return not await self.is_busy()

    async def read_output(self, n):
        """Read one output element (0..OUT_TOTAL-1) as a Python int.

        6-byte transaction [OP_O_READ, addr_hi, addr_lo, d, d, d];
        the response arrives on the last 3 bytes (proven protocol from
        tb_quadbit_conv_top.v: the SPI slave presents the latched result
        from the byte boundary after the address completes).
        """
        rx = await self._x([OP_O_READ, (n >> 8) & 0xFF, n & 0xFF, 0, 0, 0])
        return (rx[3] << 16) | (rx[4] << 8) | rx[5]

    async def read_burst(self, addr, count):
        """Read count output elements starting at addr using burst mode."""
        cmd = [OP_O_READ_BURST, (addr >> 8) & 0xFF, addr & 0xFF, (count >> 8) & 0xFF, count & 0xFF]
        rx = await self._x(cmd + [0] * (count * 3))
        out = []
        for i in range(count):
            idx = 5 + i * 3
            out.append((rx[idx] << 16) | (rx[idx+1] << 8) | rx[idx+2])
        return out

    async def read_outputs(self, count=OUT_TOTAL):
        """Use burst mode for full readout."""
        return await self.read_burst(0, count)

    async def read_outputs_single(self, count=OUT_TOTAL):
        """Read `count` output elements into a list of ints."""
        return [await self.read_output(i) for i in range(count)]

    # -- convenience: bulk programming ---------------------------------------

    async def program_weights(self, w):
        """Program a K x N weight matrix (lists of ints) and lock it."""
        for k in range(self.K):
            for n in range(self.N):
                await self.write_weight(k, n, int(w[k][n]))
        await self.lock()

    async def program_frame(self, frame):
        """Program a 28x28 frame (list of rows, ints 0..255)."""
        for r in range(self.FRAME):
            for c in range(self.FRAME):
                await self.write_frame(r, c, int(frame[r][c]))

    # -- run helpers ----------------------------------------------------------

    async def run(self, frame):
        """program_frame(frame); start(); wait until not busy; return outputs."""
        await self.program_frame(frame)
        await self.start()
        await self.wait_done()
        return await self.read_outputs()

    async def wait_done(self, tick=None, max_ticks=10_000_000):
        """Poll STATUS until the BUSY bit clears (done is latched in RTL).

        `tick` is an async callable that waits one poll interval in the
        target's time domain:
          * Pi:        tick = lambda: asyncio.sleep(0.001)
          * sim:       tick = lambda: cocotb Timer(10_000, 'ns')
        Without a tick this polls back-to-back (asyncio.sleep(0)).
        """
        for _ in range(max_ticks):
            if not await self.is_busy():
                return await self.status()
            if tick is not None:
                t = tick()
                if hasattr(t, "__await__"):
                    await t
            else:
                await asyncio.sleep(0)
        raise TimeoutError("wait_done: BUSY never cleared")
