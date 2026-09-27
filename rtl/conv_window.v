`default_nettype none

// conv_window.v — Quadbit spatial window generator (3x3)
//
// Translates a central (pos_row, pos_col) and a tap index (0..8)
// into a read address for the frame buffer, handling bounds checking
// and zero-padding.
//
// Tap ordering (row-major):
//   0 1 2
//   3 4 5
//   6 7 8
//
// Fully combinatorial logic to keep the spatial FSM simple.

module conv_window #(
  parameter ROWS   = 28,
  parameter COLS   = 28,
  parameter DATA_W = 8
) (
  // Window center position
  input  wire [$clog2(ROWS)-1:0] pos_row,
  input  wire [$clog2(COLS)-1:0] pos_col,

  // Tap index (0 to 8)
  input  wire [3:0]              tap_idx,

  // Interface to frame_buf
  output wire [$clog2(ROWS)-1:0] r_row,
  output wire [$clog2(COLS)-1:0] r_col,
  input  wire [DATA_W-1:0]       r_data,

  // Output pixel (0 if out of bounds)
  output wire [DATA_W-1:0]       pixel_out
);

  localparam [$clog2(ROWS)-1:0] ROW_MAX = ROWS[$clog2(ROWS)-1:0] - 1;
  localparam [$clog2(COLS)-1:0] COL_MAX = COLS[$clog2(COLS)-1:0] - 1;
  localparam [$clog2(ROWS)-1:0] R_ONE   = 1;
  localparam [$clog2(COLS)-1:0] C_ONE   = 1;

  reg [1:0] row_off; // 0=top, 1=mid, 2=bot
  reg [1:0] col_off; // 0=left, 1=mid, 2=right

  always @(*) begin
    case (tap_idx)
      4'd0: begin row_off = 2'd0; col_off = 2'd0; end
      4'd1: begin row_off = 2'd0; col_off = 2'd1; end
      4'd2: begin row_off = 2'd0; col_off = 2'd2; end
      4'd3: begin row_off = 2'd1; col_off = 2'd0; end
      4'd4: begin row_off = 2'd1; col_off = 2'd1; end
      4'd5: begin row_off = 2'd1; col_off = 2'd2; end
      4'd6: begin row_off = 2'd2; col_off = 2'd0; end
      4'd7: begin row_off = 2'd2; col_off = 2'd1; end
      4'd8: begin row_off = 2'd2; col_off = 2'd2; end
      default: begin row_off = 2'd1; col_off = 2'd1; end
    endcase
  end

  wire top_bad   = (row_off == 2'd0) && (pos_row == 0);
  wire bot_bad   = (row_off == 2'd2) && (pos_row == ROW_MAX);
  wire left_bad  = (col_off == 2'd0) && (pos_col == 0);
  wire right_bad = (col_off == 2'd2) && (pos_col == COL_MAX);

  wire out_of_bounds = top_bad | bot_bad | left_bad | right_bad;

  // Clamp to 0 when out of bounds to avoid wrapping addresses
  assign r_row = top_bad ? {($clog2(ROWS)){1'b0}} :
                 (row_off == 2'd0) ? pos_row - R_ONE :
                 (row_off == 2'd2) ? pos_row + R_ONE :
                 pos_row;

  assign r_col = left_bad ? {($clog2(COLS)){1'b0}} :
                 (col_off == 2'd0) ? pos_col - C_ONE :
                 (col_off == 2'd2) ? pos_col + C_ONE :
                 pos_col;

  assign pixel_out = out_of_bounds ? {DATA_W{1'b0}} : r_data;

endmodule
