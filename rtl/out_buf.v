`default_nettype none

// out_buf.v — Result buffer for the convolution feature map
//
// 16-filter output over a 26x26 spatial grid = 10816 elements.
// Stored as 24-bit values (post-ReLU) to preserve the exact dense
// engine precision semantics without truncating to 8 bits.

module out_buf #(
  parameter DEPTH  = 10816,
  parameter DATA_W = 24
) (
  input  wire                     clk,
  
  // Write port (from conv_ctrl)
  input  wire                     w_en,
  input  wire [$clog2(DEPTH)-1:0] w_addr,
  input  wire [DATA_W-1:0]        w_data,
  
  // Read port (for SPI host O_READ)
  input  wire [$clog2(DEPTH)-1:0] r_addr,
  output reg  [DATA_W-1:0]        r_data
);

  reg [DATA_W-1:0] mem [0:DEPTH-1];

  always @(posedge clk) begin
    if (w_en)
      mem[w_addr] <= w_data;
    r_data <= mem[r_addr];
  end

endmodule
