`default_nettype none

// frame_buf.v — Quadbit input frame buffer (single-channel 28x28 x 8)
//
// Stores one input frame: 28 rows x 28 cols, 8-bit unsigned pixels.
// Part of the spatial conv front-end — the window generator reads
// (r,c), (r,c+1), (r+1,c) taps from here.
//
//   - Write: synchronous, explicit (row, col) addressing
//   - Read:  combinational (SRAM-style), (row, col) -> pixel
//   - frame_full: asserted once ROWS*COLS writes seen since reset
//     (saturates — extra writes do not roll the counter over)

module frame_buf #(
  parameter ROWS   = 28,
  parameter COLS   = 28,
  parameter DATA_W = 8
) (
  input  wire                   clk,
  input  wire                   rst_n,

  // write port
  input  wire                   w_en,
  input  wire [$clog2(ROWS)-1:0]   w_row,
  input  wire [$clog2(COLS)-1:0]   w_col,
  input  wire [DATA_W-1:0]        w_data,

  // read port (combinational)
  input  wire [$clog2(ROWS)-1:0]   r_row,
  input  wire [$clog2(COLS)-1:0]   r_col,
  output wire [DATA_W-1:0]        r_data,

  // progress
  output wire                   frame_full
);

  localparam integer DEPTH  = ROWS * COLS;
  localparam integer ADDR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  localparam [15:0] DEPTH16 = DEPTH[15:0];

  reg [DATA_W-1:0] mem [0:DEPTH-1];
  reg [15:0]       wcount;

  // linear address = row*COLS + col (NOT a concatenation — that only
  // works when COLS is a power of two). Sized to ADDR_W bits for clean lint.
  localparam [ADDR_W-1:0] COLS_W = COLS[ADDR_W-1:0];
  localparam [ADDR_W-1:0] MOD_W  = DEPTH[ADDR_W-1:0];

  /* verilator lint_off WIDTHEXPAND */
  wire [ADDR_W-1:0] w_lin  = w_row * COLS_W + w_col;   // w_col zero-extends (w_col < 2^ADDR_W)
  wire [ADDR_W-1:0] r_lin  = r_row * COLS_W + r_col;
  /* verilator lint_on WIDTHEXPAND */
  wire [ADDR_W-1:0] w_addr = w_lin % MOD_W;
  wire [ADDR_W-1:0] r_addr = r_lin % MOD_W;

  assign r_data     = mem[r_addr];
  assign frame_full = (wcount == DEPTH16);

  integer i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // Start at DEPTH-1 so the Nth write makes wcount == DEPTH
      // (pre-increment semantics: frame_full is correct after exactly
      // ROWS*COLS writes). Saturates at DEPTH — extra writes are no-ops.
      wcount <= DEPTH16 - 16'd1;
      /* verilator lint_off BLKSEQ */ // blocking required for mem-init in reset
      for (i = 0; i < DEPTH; i = i + 1)
        mem[i] = {DATA_W{1'b0}};
      /* verilator lint_on BLKSEQ */
    end else if (w_en) begin
      mem[w_addr] <= w_data;
      if (wcount != DEPTH16)
        wcount <= wcount + 16'd1;
    end
  end

endmodule
