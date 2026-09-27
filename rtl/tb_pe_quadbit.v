`default_nettype none

// tb_pe_quadbit.v — testbench for pe_quadbit
module tb_pe_quadbit;
  localparam IN_W  = 8;
  localparam OUT_W = IN_W + 1;

  reg  [1:0]       w;
  reg  [IN_W-1:0]  x;
  wire [OUT_W-1:0] out;
  wire             ctrl;

  reg  [OUT_W-1:0] exp;
  reg              exp_ctrl;
  integer          errors;

  pe_quadbit #(.IN_W(IN_W)) dut (
    .w(w), .x(x), .out(out), .ctrl_flag(ctrl)
  );

  task check;
    begin
      #1;
      if (out !== exp || ctrl !== exp_ctrl) begin
        $display("FAIL: w=%b x=%0d -> out=%0d (exp %0d) ctrl=%b (exp %b)",
                 w, x, out, exp, ctrl, exp_ctrl);
        errors = errors + 1;
      end else begin
        $display("PASS: w=%b x=%0d -> out=%0d ctrl=%b", w, x, out, ctrl);
      end
    end
  endtask

  initial begin
    errors = 0;
    w = 2'bxx; x = 8'bx;
    $display("---- quadbit PE unit tests ----");

    // w=10 (+1): out = +x
    w = 2'b10;
    x = 8'd0;   exp = 9'sd0;   exp_ctrl = 1'b0; check;
    x = 8'd255; exp = 9'sd255; exp_ctrl = 1'b0; check;
    x = 8'd123; exp = 9'sd123; exp_ctrl = 1'b0; check;

    // w=01 (-1): out = -x
    w = 2'b01;
    x = 8'd0;   exp = 9'sd0;    exp_ctrl = 1'b0; check;
    x = 8'd255; exp = -9'sd255; exp_ctrl = 1'b0; check;
    x = 8'd123; exp = -9'sd123; exp_ctrl = 1'b0; check;

    // w=00 (0): out = 0, no ctrl
    w = 2'b00;
    x = 8'd255; exp = 9'sd0; exp_ctrl = 1'b0; check;
    x = 8'd1;   exp = 9'sd0; exp_ctrl = 1'b0; check;

    // w=11 (CTRL): out = 0, ctrl flag high
    w = 2'b11;
    x = 8'd255; exp = 9'sd0; exp_ctrl = 1'b1; check;
    x = 8'd0;   exp = 9'sd0; exp_ctrl = 1'b1; check;

    // X propagation check
    w = 2'b1x; x = 8'hFF; #1;
    $display("INFO: w=1x x=FF -> out=%b ctrl=%b (expect x's)", out, ctrl);

    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("%0d TEST(S) FAILED", errors);
    $finish;
  end
endmodule
