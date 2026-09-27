`default_nettype none

// quadbit_layer.v — Quadbit dense-layer engine (K inputs x N outputs)
//
//   y[j] = sum over i of  sel(w[i][j]) * x[i]
//     sel: w=10 -> +x | w=00 -> 0 | w=01 -> -x | w=11 -> 0 (+ctrl flag)
//
// Flow: PROG (load weights/enables) -> LOCK -> READY -> stream x[0..K-1]
//       -> DONE (read N sums). Reuse via k_en / n_en masks.
//
// Full target: K=784, N=512, IN_W=8, ACC_W=24.

module quadbit_layer #(
  parameter K     = 4,
  parameter N     = 2,
  parameter IN_W  = 8,
  parameter ACC_W = 24
) (
  input  wire                  clk,
  input  wire                  rst_n,

  // weight/config programming (S_PROG)
  input  wire                  w_wr_en,
  input  wire [$clog2(K)-1:0]  w_row,
  input  wire [$clog2(N)-1:0]  w_col,
  input  wire [1:0]            w_val,
  input  wire                  k_en_set,
  input  wire [K-1:0]          k_en_val,
  input  wire                  n_en_set,
  input  wire [N-1:0]          n_en_val,
  input  wire                  lock,

  // activation stream (S_READY/S_RUN)
  input  wire                  x_valid,
  input  wire [IN_W-1:0]       x_data,
  input  wire                  rearm,  // In S_DONE: clears acc and returns to S_READY

  // readout
  input  wire [$clog2(N)-1:0]  out_sel,
  output wire [ACC_W-1:0]      out_data,
  output wire [K-1:0]          ctrl_evt,
  output wire [1:0]            state,
  output wire                  done
);

  localparam OUT_W  = IN_W + 1;
  localparam IDX_W  = (K > 1) ? $clog2(K) : 1;
  localparam S_PROG  = 2'd0;
  localparam S_READY = 2'd1;
  localparam S_RUN   = 2'd2;
  localparam S_DONE  = 2'd3;

  reg  [1:0]          st;
  reg  [1:0]          w [0:K-1][0:N-1];
  reg  [ACC_W-1:0]    acc [0:N-1];
  reg  [K-1:0]        ctrl_evt_r;
  reg  [K-1:0]        k_en;
  reg  [N-1:0]        n_en;
  reg  [IDX_W-1:0]    x_idx;

  wire [OUT_W-1:0]    pe_out [0:K-1][0:N-1];

  genvar gi, gj;
  genvar cc;

  // per-input control flag = OR over its N weights of (w==11)
  wire [K-1:0] ctrl_all;
  wire [N-1:0] is_ctrl [0:K-1];
  generate
    for (gi = 0; gi < K; gi = gi + 1) begin : cgen
      for (cc = 0; cc < N; cc = cc + 1) begin : cbit
        assign is_ctrl[gi][cc] = (w[gi][cc] == 2'b11);
      end
      assign ctrl_all[gi] = |is_ctrl[gi];
    end
  endgenerate
  generate
    for (gi = 0; gi < K; gi = gi + 1) begin : gin
      for (gj = 0; gj < N; gj = gj + 1) begin : gjn
        /* verilator lint_off PINCONNECTEMPTY */
        pe_quadbit #(.IN_W(IN_W)) u_pe (
          .w(w[gi][gj]),
          .x(x_data),
          .out(pe_out[gi][gj]),
          .ctrl_flag()
        );
        /* verilator lint_on PINCONNECTEMPTY */
      end
    end
  endgenerate

  assign ctrl_evt   = ctrl_evt_r;
  assign out_data   = acc[out_sel];
  assign state      = st;
  assign done       = (st == S_DONE);

  wire [IDX_W-1:0] cur_idx  = (st == S_READY) ? {IDX_W{1'b0}} : x_idx;
  wire [IDX_W-1:0] last_idx = (K > 1) ? (K[IDX_W-1:0] - 1'b1) : {IDX_W{1'b0}};

  // signed-extend a PE output to accumulator width
  function [ACC_W-1:0] sext;
    input [OUT_W-1:0] v;
    sext = {{(ACC_W-OUT_W){v[OUT_W-1]}}, v};
  endfunction

  integer i, j;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st         <= S_PROG;
      k_en       <= {K{1'b1}};
      n_en       <= {N{1'b1}};
      ctrl_evt_r <= {K{1'b0}};
      x_idx      <= {IDX_W{1'b0}};
      for (i = 0; i < N; i = i + 1) acc[i] <= {ACC_W{1'b0}};
      for (i = 0; i < K; i = i + 1)
        for (j = 0; j < N; j = j + 1) w[i][j] <= 2'b00;
    end else begin
      case (st)
        S_PROG: begin
          if (w_wr_en)  w[w_row][w_col] <= w_val;
          if (k_en_set) k_en <= k_en_val;
          if (n_en_set) n_en <= n_en_val;
          if (lock) begin
            for (i = 0; i < N; i = i + 1) acc[i] <= {ACC_W{1'b0}};
            ctrl_evt_r <= {K{1'b0}};
            x_idx      <= {IDX_W{1'b0}};
            st         <= S_READY;
          end
        end
        S_READY: if (x_valid) begin
          if (k_en[0])
            for (i = 0; i < N; i = i + 1)
              if (n_en[i])
                acc[i] <= acc[i] + sext(pe_out[0][i]);
          if (k_en[0]) ctrl_evt_r[0] <= ctrl_evt_r[0] | ctrl_all[0];
          if (K == 1) x_idx <= {IDX_W{1'b0}};
          else        x_idx <= {{(IDX_W-1){1'b0}}, 1'b1};
          st    <= (K == 1) ? S_DONE : S_RUN;
        end
        S_RUN: if (x_valid) begin
          if (k_en[cur_idx])
            for (i = 0; i < N; i = i + 1)
              if (n_en[i])
                acc[i] <= acc[i] + sext(pe_out[cur_idx][i]);
          if (k_en[cur_idx])
            ctrl_evt_r[cur_idx] <= ctrl_evt_r[cur_idx] | ctrl_all[cur_idx];
          if (cur_idx == last_idx)
            st <= S_DONE;
          else
            x_idx <= cur_idx + 1'b1;
        end
        S_DONE: if (rearm) begin
          for (i = 0; i < N; i = i + 1) acc[i] <= {ACC_W{1'b0}};
          ctrl_evt_r <= {K{1'b0}};
          x_idx      <= {IDX_W{1'b0}};
          st         <= S_READY;
        end
        default: ;
      endcase
    end
  end

endmodule
