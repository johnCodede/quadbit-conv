`default_nettype none

// tb_frame_buf.v — frame buffer testbench
//
// Checks:
//   1. frame_full == 0 after reset
//   2. Write all 784 pixels with a known pattern
//   3. frame_full == 1 exactly after the 784th write
//   4. Read back every pixel (combinational) and compare
//   5. Overwrite one pixel, verify the new value
//
// NOTE: no `task` with `output` port args (Icarus vvp hangs on that).

`timescale 1ns/1ps

module tb_frame_buf;

  localparam ROWS = 28;
  localparam COLS = 28;
  localparam W    = 8;

  reg         clk;
  reg         rst_n;

  reg         w_en;
  reg  [4:0]  w_row;
  reg  [4:0]  w_col;
  reg  [7:0]  w_data;

  reg  [4:0]  r_row;
  reg  [4:0]  r_col;
  wire [7:0]  r_data;
  wire        frame_full;

  frame_buf #(.ROWS(ROWS), .COLS(COLS), .DATA_W(W)) dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .w_en       (w_en),
    .w_row      (w_row),
    .w_col      (w_col),
    .w_data     (w_data),
    .r_row      (r_row),
    .r_col      (r_col),
    .r_data     (r_data),
    .frame_full (frame_full)
  );

  always #5 clk = ~clk;

  integer errors;
  integer r, c;
  reg [7:0] expected;

  // write one pixel (no output port in task — safe for vvp)
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

  initial begin
    clk = 0;
    rst_n = 0;
    w_en = 0; w_row = 0; w_col = 0; w_data = 0;
    r_row = 0; r_col = 0;
    errors = 0;

    // reset
    #10;
    @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // 1. frame_full low after reset
    if (frame_full !== 1'b0) begin
      $display("FAIL: frame_full should be 0 after reset");
      errors = errors + 1;
    end

    // 2. write all pixels: pattern = (r*COLS + c) & 0xFF
    for (r = 0; r < ROWS; r = r + 1)
      for (c = 0; c < COLS; c = c + 1) begin
        expected = (r * COLS + c) & 8'hFF;
        wr(r[4:0], c[4:0], expected);
      end

    // 3. frame_full should be high now
    if (frame_full !== 1'b1) begin
      $display("FAIL: frame_full should be 1 after %0d writes", ROWS*COLS);
      errors = errors + 1;
    end else begin
      $display("PASS: frame_full asserted after %0d writes", ROWS*COLS);
    end

    // 4. read back every pixel and compare
    for (r = 0; r < ROWS; r = r + 1) begin
      for (c = 0; c < COLS; c = c + 1) begin
        r_row = r[4:0];
        r_col = c[4:0];
        #2;  // combinational read — settle
        expected = (r * COLS + c) & 8'hFF;
        if (r_data !== expected) begin
          $display("FAIL: read(%0d,%0d)=%0d expected %0d", r, c, r_data, expected);
          errors = errors + 1;
          if (errors > 20) begin
            $display("ABORT: too many read errors");
            $finish;
          end
        end
      end
    end
    $display("PASS: all %0d pixels read back correctly", ROWS*COLS);

    // 5. overwrite one pixel and verify
    wr(5'd13, 5'd7, 8'hC3);
    r_row = 5'd13;
    r_col = 5'd7;
    #2;
    if (r_data !== 8'hC3) begin
      $display("FAIL: overwrite read=%0h expected C3", r_data);
      errors = errors + 1;
    end else begin
      $display("PASS: overwrite + readback ok (0xC3)");
    end

    // 6. extra writes must NOT wrap frame_full
    wr(5'd0, 5'd0, 8'h00);
    #2;
    if (frame_full !== 1'b1) begin
      $display("FAIL: frame_full dropped after extra write");
      errors = errors + 1;
    end

    if (errors == 0)
      $display("ALL TESTS PASSED");
    else
      $display("%0d ERRORS", errors);
    $finish;
  end

endmodule
