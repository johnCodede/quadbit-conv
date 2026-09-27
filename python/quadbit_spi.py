"""quadbit_spi.py — fake SPI transport for simulation (spidev-compatible API).

Drop-in stand-in for the Raspberry Pi's `spidev.SPIDevice` so that the
command layer (quadbit_driver.QuadbitConv) and the tests can be written
once and run against:

  * simulation:  QuadbitSpi(dut)          <- this module (cocotb + Icarus)
  * real chip:   spidev.SPIDevice(bus, d) <- same .xfer() API

Protocol (see SPI.md):
  * SPI mode 0 (CPOL=0, CPHA=0), MSB first, one CS transaction per command.
  * The DUT samples `spi_mosi` on the SCLK rising edge; MISO is sampled by
    the master on the same edge and the DUT shifts the next bit out on the
    falling edge.

The API surface intentionally matches spidev:
  spi = QuadbitSpi(dut)      # ~ spidev.SPIDevice(0, 0)
  rx = await spi.xfer(tx)    # ~ spi.xfer(tx)      (list[int] -> list[int])
  rx = await spi.xfer3(tx)   # ~ spi.xfer3(tx)     (full-duplex, 1:1)
  spi.close()
"""

from cocotb.triggers import Timer


class QuadbitSpi:
    """spidev-compatible SPI master backed by a cocotb DUT.

    Parameters
    ----------
    dut : cocotb DUT
        Must expose the top-level pins: spi_cs_n, spi_sclk, spi_mosi, spi_miso.
    half_ns : int
        Half SCLK period in ns. 40 ns full period -> 25 MHz (default).
    """

    def __init__(self, dut, half_ns=20):
        self.dut = dut
        self._half_ns = int(half_ns)
        self._closed = False

    # -- spidev-compatible surface ------------------------------------------

    @property
    def max_speed_hz(self):
        return int(1e9 / (2 * self._half_ns))

    @max_speed_hz.setter
    def max_speed_hz(self, hz):
        self._half_ns = max(1, int(1e9 / (2 * hz)))

    def close(self):
        self.dut.spi_cs_n.value = 1
        self._closed = True

    # -- one CS transaction --------------------------------------------------

    async def _settle(self):
        await Timer(self._half_ns, unit="ns")

    def _sample(self, sig):
        """Read one DUT bit, masking X/Z -> 0.

        A real SPI master reads an undriven/high-impedance MISO as a level,
        never as an exception. The DUT leaves MISO = X until its first
        cs_n-release edge (conv_spi_ctrl has no power-on reset), so the
        write-phase bytes of the first transaction read 0 here; that is
        correct because write-only commands never use MISO.
        """
        v = sig.value
        try:
            return int(v)
        except (ValueError, TypeError):
            return 0

    async def _clock_byte(self, tx):
        """Clock one byte in (MSB first), return the byte read from MISO."""
        rx = 0
        for i in range(7, -1, -1):
            self.dut.spi_mosi.value = (tx >> i) & 1
            await self._settle()
            self.dut.spi_sclk.value = 1            # rising: DUT samples mosi
            await self._settle()
            rx = (rx << 1) | self._sample(self.dut.spi_miso)
            self.dut.spi_sclk.value = 0            # falling: DUT shifts next out
            await self._settle()
        return rx

    async def xfer(self, tx):
        """One CS transaction: CS low, clock all bytes, CS high.

        `tx` is a list of ints (0..255); returns the list of bytes read.
        Matches spidev.SPIDevice.xfer().
        """
        dut = self.dut
        dut.spi_cs_n.value = 1
        await self._settle()
        dut.spi_cs_n.value = 0
        await self._settle()
        rx = [await self._clock_byte(b & 0xFF) for b in tx]
        await self._settle()
        dut.spi_cs_n.value = 1
        await self._settle()
        return rx

    async def xfer3(self, tx):
        """Full-duplex, 1:1 (spidev.xfer3): same as xfer for this DUT."""
        return await self.xfer(tx)


def open(dut, half_ns=20):  # noqa: A001 - mimics spidev.open()
    """Module-level factory mirroring `spidev.SPIDevice(...)`.

    Usage in sim:      spi = quadbit_spi.open(dut)
    Usage on the Pi:   spi = spidev.SPIDevice(0, 0)
    """
    return QuadbitSpi(dut, half_ns=half_ns)
