`default_nettype none

// spi_slave.v — 4-wire SPI mode-0 slave, 8-bit byte-framed
//
// Mode 0: CPOL=0, CPHA=0
//   - SCLK idles LOW
//   - Slave samples MOSI on rising edge
//   - Slave updates MISO on falling edge
//   - Master samples MISO on rising edge
//
// Byte interface (one byte per 8 SCLK cycles, MSB-first):
//   - rx_data / rx_valid: received byte + 1-cycle valid pulse
//   - tx_data: byte to present on MISO (auto-loaded each byte boundary)
//
// CS# high resets bit counters; async rst_n gives a defined power-on state
// (real silicon flip-flops power up undefined — CS self-sync alone would
// leave the first transaction after power-up running on X counters).

module spi_slave (
  input  wire       sclk,
  input  wire       cs_n,
  input  wire       mosi,
  input  wire       rst_n,
  output wire       miso,

  output wire [7:0] rx_data,
  output wire       rx_valid,
  input  wire [7:0] tx_data
);

  reg  [7:0] rx_shift;
  reg  [7:0] tx_shift;
  reg  [2:0] rx_bit;
  reg  [2:0] tx_bit;
  reg        rx_valid_r;

  assign rx_data  = rx_shift;
  assign rx_valid = rx_valid_r;
  assign miso     = tx_shift[7];

  // ---- RX: sample MOSI on posedge ----
  always @(posedge sclk or posedge cs_n or negedge rst_n) begin
    if (!rst_n) begin
      rx_shift   <= 8'h00;
      rx_bit     <= 3'd0;
      rx_valid_r <= 1'b0;
    end else if (cs_n) begin
      rx_shift   <= 8'h00;
      rx_bit     <= 3'd0;
      rx_valid_r <= 1'b0;
    end else begin
      rx_shift   <= {rx_shift[6:0], mosi};
      if (rx_bit == 3'd7) begin
        rx_bit     <= 3'd0;
        rx_valid_r <= 1'b1;
      end else begin
        rx_bit     <= rx_bit + 3'd1;
        rx_valid_r <= 1'b0;
      end
    end
  end

  // ---- TX: shift out on negedge ----
  // MISO = tx_shift[7]. Master samples on the next posedge.
  // After 8 negedges, load the next byte from tx_data.
  always @(negedge sclk or posedge cs_n or negedge rst_n) begin
    if (!rst_n) begin
      tx_shift <= 8'h00;
      tx_bit   <= 3'd0;
    end else if (cs_n) begin
      tx_shift <= tx_data;
      tx_bit   <= 3'd0;
    end else begin
      if (tx_bit == 3'd7) begin
        tx_shift <= tx_data;   // byte boundary: load next byte
        tx_bit   <= 3'd0;
      end else begin
        tx_shift <= {tx_shift[6:0], 1'b0};
        tx_bit   <= tx_bit + 3'd1;
      end
    end
  end

endmodule
