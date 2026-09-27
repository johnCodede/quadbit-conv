`default_nettype none

// tb_quadbit_layer.v — end-to-end test of quadbit_layer vs reference
module tb_quadbit_layer;

  localparam K     = 4;
  localparam N     = 3;
  localparam IN_W  = 8;
  localparam ACC_W = 24;
  localparam IDX_W = $clog2(K);
  localparam JIDX_W= $clog2(N);

  reg                 clk;
  reg                 rst_n;
  reg                 w_wr_en;
  reg  [IDX_W-1:0]    w_row;
  reg  [JIDX_W-1:0]   w_col;
  reg  [1:0]          w_val;
  reg                 k_en_set;
  reg  [K-1:0]        k_en_val;
  reg                 n_en_set;
  reg  [N-1:0]        n_en_val;
  reg                 lock;
  reg                 x_valid;
  reg  [IN_W-1:0]     x_data;
  reg  [JIDX_W-1:0]   out_sel;
  wire [ACC_W-1:0]    out_data;
  wire [K-1:0]        ctrl_evt;
  wire [1:0]          state;
  wire                done;

  integer errors = 0;

  quadbit_layer #(.K(K),.N(N),.IN_W(IN_W),.ACC_W(ACC_W)) dut (
    .clk(clk), .rst_n(rst_n),
    .w_wr_en(w_wr_en), .w_row(w_row), .w_col(w_col), .w_val(w_val),
    .k_en_set(k_en_set), .k_en_val(k_en_val),
    .n_en_set(n_en_set), .n_en_val(n_en_val),
    .lock(lock),
    .x_valid(x_valid), .x_data(x_data),
    .rearm(1'b0),
    .out_sel(out_sel), .out_data(out_data),
    .ctrl_evt(ctrl_evt), .state(state), .done(done)
  );

  always #5 clk = ~clk;

  // reference: expected[j] = sum_i sel(w[i][j]) * x[i]
  function [ACC_W-1:0] sel;
    input [1:0] code;
    sel = (code == 2'b10) ? 1 :
          (code == 2'b01) ? -1 : 0;
  endfunction

  function [ACC_W-1:0] ref_sum;
    input [JIDX_W-1:0] j;
    integer i;
    reg [ACC_W-1:0] s;
    begin
      s = 0;
      for (i = 0; i < K; i = i + 1)
        s = s + sel(w_stored[i][j]) * $signed(x_stored[i]);
      ref_sum = s;
    end
  endfunction

  // stored copies of weights/inputs for reference (testbench-side)
  reg [1:0]      w_stored [0:K-1][0:N-1];
  reg [IN_W-1:0] x_stored [0:K-1];

  task load_weight(input [IDX_W-1:0] r, input [JIDX_W-1:0] c, input [1:0] v);
    begin
      @(negedge clk);
      w_wr_en = 1; w_row = r; w_col = c; w_val = v; w_stored[r][c] = v;
      @(negedge clk);
      w_wr_en = 0;
    end
  endtask

  task do_lock;
    begin
      @(negedge clk); lock = 1; @(negedge clk); lock = 0;
      // wait for READY
      while (state != 2'd1) @(negedge clk);
    end
  endtask

  task stream_x(input [IN_W-1:0] v, input [IDX_W-1:0] idx);
    begin
      x_stored[idx] = v;
      @(negedge clk);
      x_valid = 1; x_data = v;
      @(negedge clk);
      x_valid = 0;
      // wait one cycle for accumulate
      @(negedge clk);
    end
  endtask

  task check_out(input [JIDX_W-1:0] j);
    begin
      out_sel = j;
      @(negedge clk);
      if (out_data !== ref_sum(j)) begin
        $display("FAIL: out[%0d]=%0d expected %0d", j, out_data, ref_sum(j));
        errors = errors + 1;
      end else begin
        $display("PASS: out[%0d]=%0d", j, out_data);
      end
    end
  endtask

  initial begin
    clk=0; rst_n=0;
    w_wr_en=0; k_en_set=0; n_en_set=0; lock=0; x_valid=0;
    k_en_val={K{1'b1}}; n_en_val={N{1'b1}};
    w_row=0; w_col=0; w_val=2'b00; x_data=0; out_sel=0;

    // ---- Reset ----
    repeat(3) @(negedge clk);
    rst_n = 1;
    repeat(2) @(negedge clk);

    // ---- Program weights: 4x3 matrix ----
    //   j=0   j=1   j=2
    // i=0:  +1    0   -1
    // i=1:  -1    +1  0
    // i=2:   0   -1  +1
    // i=3:  +1   +1  11(ctrl)
    load_weight(0,0,2'b10); load_weight(0,1,2'b00); load_weight(0,2,2'b01);
    load_weight(1,0,2'b01); load_weight(1,1,2'b10); load_weight(1,2,2'b00);
    load_weight(2,0,2'b00); load_weight(2,1,2'b01); load_weight(2,2,2'b10);
    load_weight(3,0,2'b10); load_weight(3,1,2'b10); load_weight(3,2,2'b11);

    // ---- Lock ----
    do_lock;
    $display("LOCKED, state=%b", state);

    // ---- Stream activations: x = [10, 20, 30, 40] ----
    // ref[0] = +1*10 + (-1)*20 + 0*30 + +1*40 = 10-20+0+40 = 30
    // ref[1] =  0*10 + +1*20 + (-1)*30 + +1*40 = 0+20-30+40 = 30
    // ref[2] = -1*10 +  0*20 + +1*30 +  0*40  = -10+0+30+0  = 20  (i=3 is ctrl->0)
    stream_x(8'd10, 0);
    stream_x(8'd20, 1);
    stream_x(8'd30, 2);
    stream_x(8'd40, 3);

    // wait for DONE
    while (!done) @(negedge clk);
    $display("DONE reached. ctrl_evt=%b", ctrl_evt);
    // i=3, j=2 was ctrl (w=11), so ctrl_evt[3] should be set
    if (ctrl_evt[3] !== 1'b1) begin
      $display("FAIL: ctrl_evt[3] should be 1"); errors = errors+1;
    end else $display("PASS: ctrl_evt[3]=1");

    // ---- Readout ----
    check_out(0);
    check_out(1);
    check_out(2);

    if (errors == 0) $display("=== ALL LAYER TESTS PASSED ===");
    else             $display("=== %0d FAILED ===", errors);
    $finish;
  end

endmodule
