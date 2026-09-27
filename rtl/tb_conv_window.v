`default_nettype none
`timescale 1ns/1ps

// tb_conv_window.v — tests the bounds-checked 3x3 window generator
//
// Checks:
//   1. Top-left corner (0,0) — taps 0..3 and 6 padded to 0
//   2. Center (1,1) — all taps valid, matches frame values
//   3. Bottom-right (27,27) — right and bottom edges padded to 0

module tb_conv_window;

  localparam ROWS = 28;
  localparam COLS = 28;
  localparam W    = 8;

  reg clk, rst_n;

  // frame_buf write interface
  reg         w_en;
  reg  [4:0]  w_row, w_col;
  reg  [7:0]  w_data;

  // conv_window interface
  reg  [4:0]  pos_row, pos_col;
  reg  [3:0]  tap_idx;
  wire [4:0]  r_row, r_col;
  wire [7:0]  r_data, pixel_out;

  frame_buf #(.ROWS(ROWS), .COLS(COLS), .DATA_W(W)) u_buf (
    .clk(clk), .rst_n(rst_n),
    .w_en(w_en), .w_row(w_row), .w_col(w_col), .w_data(w_data),
    .r_row(r_row), .r_col(r_col), .r_data(r_data),
    .frame_full()
  );

  conv_window #(.ROWS(ROWS), .COLS(COLS), .DATA_W(W)) u_win (
    .pos_row(pos_row), .pos_col(pos_col), .tap_idx(tap_idx),
    .r_row(r_row), .r_col(r_col), .r_data(r_data),
    .pixel_out(pixel_out)
  );

  always #5 clk = ~clk;

  task wr(input [4:0] row, input [4:0] col, input [7:0] d);
    begin
      @(posedge clk);
      w_en   <= 1'b1;
      w_row  <= row;
      w_col  <= col;
      w_data <= d;
      @(posedge clk);
      w_en   <= 1'b0;
    end
  endtask

  integer errors = 0;
  integer r, c, t;
  reg [7:0] exp;

  initial begin
    clk = 0; rst_n = 0; w_en = 0;
    w_row = 0; w_col = 0; w_data = 0;
    pos_row = 0; pos_col = 0; tap_idx = 0;
    
    #10; @(posedge clk); rst_n = 1; @(posedge clk);

    // 1. Fill frame_buf with (r*COLS + c)
    for (r = 0; r < ROWS; r = r + 1)
      for (c = 0; c < COLS; c = c + 1)
        wr(r[4:0], c[4:0], (r * COLS + c) & 8'hFF);

    // 2. Test corner (0,0)
    pos_row = 5'd0; pos_col = 5'd0;
    for (t = 0; t < 9; t = t + 1) begin
      tap_idx = t[3:0];
      #2; // combinational settle
      // expected: padding for left/top
      if (t == 0 || t == 1 || t == 2 || t == 3 || t == 6) exp = 0;
      else if (t == 4) exp = 0; // (0,0)
      else if (t == 5) exp = 1; // (0,1)
      else if (t == 7) exp = 28; // (1,0)
      else if (t == 8) exp = 29; // (1,1)

      if (pixel_out !== exp) begin
        $display("FAIL (0,0): tap %0d -> %0d (expected %0d)", t, pixel_out, exp);
        errors = errors + 1;
      end
    end

    // 3. Test center (1,1) -> all valid
    pos_row = 5'd1; pos_col = 5'd1;
    for (t = 0; t < 9; t = t + 1) begin
      tap_idx = t[3:0];
      #2;
      exp = (t==0)? 0 : (t==1)? 1 : (t==2)? 2 :
            (t==3)? 28: (t==4)? 29: (t==5)? 30:
            (t==6)? 56: (t==7)? 57: (t==8)? 58: 8'h00;
      if (pixel_out !== exp) begin
        $display("FAIL (1,1): tap %0d -> %0d (expected %0d)", t, pixel_out, exp);
        errors = errors + 1;
      end
    end

    // 4. Test bottom-right (27,27)
    pos_row = 5'd27; pos_col = 5'd27;
    for (t = 0; t < 9; t = t + 1) begin
      tap_idx = t[3:0];
      #2;
      if (t == 2 || t == 5 || t == 6 || t == 7 || t == 8) exp = 0; // padded
      else if (t == 0) exp = ((26 * 28 + 26) & 8'hFF);
      else if (t == 1) exp = ((26 * 28 + 27) & 8'hFF);
      else if (t == 3) exp = ((27 * 28 + 26) & 8'hFF);
      else if (t == 4) exp = ((27 * 28 + 27) & 8'hFF);
      
      if (pixel_out !== exp) begin
        $display("FAIL (27,27): tap %0d -> %0d (expected %0d)", t, pixel_out, exp);
        errors = errors + 1;
      end
    end

    if (errors == 0)
      $display("ALL TESTS PASSED");
    else
      $display("%0d ERRORS", errors);
    $finish;
  end
endmodule
