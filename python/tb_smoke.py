# tb_smoke.py — cocotb smoke test: Python -> SPI -> quadbit_conv_top bridge check.
#
# Verifies: cocotb/Icarus VPI bridge, sys_clk generation, reset behavior,
# and the byte-level SPI driver against the real DUT (STATUS command).

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

HALF = 20  # ns, half sclk period (40ns full) — same ratio as the Verilog TB


async def settle(dut, ns=20):
    await Timer(ns, unit="ns")


async def spi_bytes(dut, tx_list):
    dut.spi_cs_n.value = 1
    await settle(dut)
    dut.spi_cs_n.value = 0
    await settle(dut)
    rx_list = []
    for tx in tx_list:
        rx = 0
        for i in range(7, -1, -1):
            dut.spi_mosi.value = (tx >> i) & 1
            await settle(dut)
            dut.spi_sclk.value = 1
            await settle(dut)
            rx = (rx << 1) | int(dut.spi_miso.value)
            dut.spi_sclk.value = 0
            await settle(dut)
        rx_list.append(rx)
    await settle(dut)
    dut.spi_cs_n.value = 1
    await settle(dut)
    return rx_list

async def spi_xfer(dut, tx_list):
    """One CS transaction: clock bytes in MSB-first, return MISO bytes read."""
    dut.spi_cs_n.value = 1
    await settle(dut)
    dut.spi_cs_n.value = 0
    await settle(dut)
    rx_list = []
    for tx in tx_list:
        rx = 0
        for i in range(7, -1, -1):
        dut.spi_mosi.value = (tx >> i) & 1
        await settle(dut)
        dut.spi_sclk.value = 1          # rising edge: DUT samples mosi
        await settle(dut)
        rx = (rx << 1) | int(dut.spi_miso.value)
        dut.spi_sclk.value = 0          # falling edge: DUT shifts next miso bit
            await settle(dut)
        rx_list.append(rx)
    await settle(dut)
    dut.spi_cs_n.value = 1
    await settle(dut)
    return rx_list


@cocotb.test()
async def smoke(dut):
    cocotb.start_soon(Clock(dut.sys_clk, 10, unit="ns").start())

    dut.sys_rst_n.value = 0
    dut.spi_sclk.value = 0
    dut.spi_cs_n.value = 1
    dut.spi_mosi.value = 0
    await Timer(100, unit="ns")
    dut.sys_rst_n.value = 1
    await Timer(100, unit="ns")

    # STATUS (0x07): single-byte command, MISO carries the status byte.
    await spi_byte(dut, 0x07)
    st = (await spi_bytes(dut, [0x07, 0x07]))[1] # Read fresh status on second byte
    dut.log.info("STATUS after reset: 0x%02x", st)
    assert (st & 0x40) != 0, "ready bit expected (MAC in S_PROG after reset)"
    assert (st & 0x10) != 0, "busy bit expected (conv not yet run)"
    dut.log.info("SMOKE PASS")
