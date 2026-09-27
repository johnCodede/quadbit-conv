# Quadbit — SPI Command & Protocol Spec

Target host: Raspberry Pi (or any SPI master). Chip = slave.

## 1. Physical / electrical layer

- **Signals:** `SCLK`, `CS#` (active-low), `MOSI` (host→chip), `MISO` (chip→host).
- **SPI mode:** **Mode 0** — `CPOL=0`, `CPHA=0`.
  - SCLK idles **LOW**.
  - Slave **samples MOSI on the rising edge**.
  - Slave **updates MISO on the falling edge**.
  - Master **samples MISO on the rising edge**.
- **Bit order:** **MSB-first** within every byte.
- **Clock:** ~20–25 MHz nominal (130 nm target can run 150–200 MHz).
- **Framing:** 8-bit bytes. `CS#` frames a transaction — a run of back-to-back bytes
  with `CS#` low. `CS#` stays low across all bytes of a multi-byte command, and going high resets the transport and loads the next TX byte. Each distinct command must be separated by a `CS#` high idle period.
- **Duplex:** full-duplex. MOSI and MISO are independent; a command byte on MOSI is
  paired with a status/ACK byte on MISO in the same 8-clock window.

> `spi_slave.v` implements exactly this transport (byte-framed, mode 0, full-duplex)
> and is **simulated + `verilator -Wall` clean**. It exposes `rx_data`/`rx_valid`
> (received byte + valid pulse) and takes `tx_data` (byte to send). Command decoding
> (section 2) is the next block — an FSM on top of this transport.

## 2. Command protocol (spec — FSM to be implemented)

Every command = a byte stream inside one CS#-framed transaction:

```
[ OPCODE ] [ arg bytes... ]
```

- **Byte 0** is the 8-bit OPCODE (on MOSI).
- In that same 8-clock window the slave returns a **STATUS/ACK byte** (on MISO).
  The master reads it at a predictable position: it is the first byte of the reply.
- **Arg bytes** follow the opcode, MSB-first, in the order below.
- Multi-byte replies (e.g. `O_READ`) are streamed on MISO over the following clock
  cycles, MSB-first, one byte per 8 SCLK.

### Opcode map

| OPCODE | Name      | Arg bytes (MOSI, in order)                     | Reply (MISO)                                   |
|:------:|-----------|------------------------------------------------|------------------------------------------------|
| `0x01` | `RESET`   | —                                              | status byte                                    |
| `0x02` | `W_WRITE` | `k_hi`,`k_lo`,`n`,`w`                          | status byte                                    |
| `0x03` | `W_LOCK`  | —                                              | status byte                                    |
| `0x04` | `START`   | —                                              | status byte                                    |
| `0x05` | `I_STREAM`| `a`                                            | status byte                                    |
| `0x06` | `O_READ`  | `n_hi`,`n_lo`                                  | `acc[23:16]`,`acc[15:8]`,`acc[7:0]`            |
| `0x07` | `STATUS`  | `0x07` (dummy)                                 | `stale_status`, `fresh_status`                 |

### Argument encodings

- **`k`** — input index, 0..783 (10 bits). `k_hi` = bits [9:2], `k_lo` = bits [1:0]+pad.
- **`n`** — output/accumulator index, 0..511 (9 bits). `n_hi` = bits [8:1], `n_lo` = bits [0]+pad.
  (`n_hi`,`n_lo` is a 2-byte 16-bit field so the encoder is uniform; upper bits are ignored.)
- **`w`** — quadbit weight, low 2 bits meaningful:
  - `00` = skip (contributes 0)
  - `01` = −1
  - `10` = +1
  - `11` = CTRL (0 + control flag, host-selectable semantics)
- **`a`** — activation, 8-bit unsigned, 0..255.
- **`acc`** — accumulator, 24-bit signed, returned MSB-first (3 bytes).

### Status byte (MISO, in the opcode window)

| Bit | Meaning |
|:---:|---------|
| 7   | `ERROR` — 1 = command rejected (see bits [3:0] code), 0 = accepted |
| 6   | `READY` — 1 = engine in S_PROG state (ready to accept weights/activations). Mutually exclusive with `LOCKED`. |
| 5   | `LOCKED`— 1 = weights locked (engine in S_READY state). Mutually exclusive with `READY`. |
| 4   | `BUSY`  — 1 = not done (running, or not yet run since RESET/START). **Sticky level** — `done` latches on completion and is cleared only by the next `START` or `RESET`, so it is safe to poll over SPI |
| [3:0]| `ERRCODE` — 0 = none; 1 = not locked before `START`; 2 = `I_STREAM` after done; 3 = bad opcode; 4 = addr out of range |

### Typical sequence (one layer eval)

```
CS# low
  0x01                 ; RESET
  0x02 k k n w  (× K×N) ; W_WRITE all weights
  0x03                 ; W_LOCK
  0x04                 ; START
  0x05 a (× K)         ; I_STREAM activations k=0..K-1
  0x06 n n (× N)       ; O_READ each output accumulator
CS# high
```

## 3. Assumptions / open
- **ACK alignment:** status byte returned in the same 8-clock window as its opcode.
  (Alternative: dedicated ACK byte after args — pick one when writing the FSM; current spec = aligned.)
- **Weight storage & addressing** inside `quadbit_layer` must match the `k`,`n` fields above.
- **`START`** semantics: begin a sweep. `done` is a sticky level (auto-acknowledged by the next `START` or cleared by `RESET`); `n_int` is the complement, held low until then. A 1-cycle done pulse would be uncatchable by a polling host.
- Full-chip sim (host↔chip) vs Python MNIST reference is the acceptance test once the FSM lands.

## Files
- `rtl/spi_slave.v` — transport (byte-framed mode-0 slave). DONE + tested.
- `rtl/tb_spi_slave.v` — transport testbench (RX 0xA5/0x12/0x34, TX 0x3C; multi-byte).
- `rtl/quadbit_layer.v` — GEMM engine the commands drive (DONE + tested).
- `DESIGN.md` — architecture log + locked decisions.
