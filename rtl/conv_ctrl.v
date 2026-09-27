`default_nettype none

// conv_ctrl.v — Spatial Convolution FSM
//
// Orchestrates the 3x3 convolution layer over a 28x28 input frame to
// produce a 26x26 output feature map. Uses a K=9, N=16 instance of the
// quadbit_layer as the MAC engine.

module conv_ctrl #(
  parameter ROWS = 28,
  parameter COLS = 28,
  parameter OUT_R = 26,
  parameter OUT_C = 26,
  parameter N = 16,
  parameter DATA_W = 8,
  parameter ACC_W = 24
) (
  input  wire clk,
  input  wire rst_n,

  // Host control
  input  wire start,
  output wire done,

  // Interface to conv_window
  output reg  [$clog2(ROWS)-1:0] pos_row,
  output reg  [$clog2(COLS)-1:0] pos_col,
  output reg  [3:0]              tap_idx,
  input  wire [DATA_W-1:0]       pixel_in,

  // Interface to quadbit_layer (MAC engine)
  output reg                     x_valid,
  output wire [DATA_W-1:0]       x_data,
  output reg                     rearm,
  output reg  [$clog2(N)-1:0]    out_sel,
  input  wire [ACC_W-1:0]        layer_out,
  /* verilator lint_off UNUSEDSIGNAL */
  input  wire [1:0]              layer_state,
  /* verilator lint_on UNUSEDSIGNAL */
  input  wire                    layer_done,

  // Interface to out_buf
  output reg                     ob_we,
  output reg  [13:0]             ob_addr,
  output wire [ACC_W-1:0]        ob_data
);

  localparam [2:0] S_IDLE       = 3'd0;
  localparam [2:0] S_TAP_SETUP  = 3'd1;
  localparam [2:0] S_TAP_DRIVE  = 3'd2;
  localparam [2:0] S_WAIT_MAC   = 3'd3;
  localparam [2:0] S_READOUT    = 3'd4;
  localparam [2:0] S_NEXT_POS   = 3'd5;
  localparam [2:0] S_DONE       = 3'd6;

  reg [2:0] state;
  reg [4:0] f_idx; // 0..16 (needs to reach 16 to finish)

  // MAC engine layer states
  // S_READY = 2'd1, S_RUN = 2'd2, S_DONE = 2'd3

  assign x_data  = pixel_in;
  // assign out_sel = f_idx[$clog2(N)-1:0];

  // ReLU: if signed bit is 1 (negative), output 0
  wire [ACC_W-1:0] relu_out = layer_out[ACC_W-1] ? {ACC_W{1'b0}} : layer_out;
  assign ob_data = relu_out;

  wire [13:0] linear_pos = {9'b0, pos_row} * 14'd26 + {9'b0, pos_col};

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= S_IDLE;
      pos_row <= 0;
      pos_col <= 0;
      tap_idx <= 0;
      x_valid <= 0;
      rearm   <= 0;
      ob_we   <= 0;
      ob_addr <= 0;
      f_idx   <= 0;
    end else begin
      x_valid <= 0;
      rearm   <= 0;
      ob_we   <= 0;

      case (state)
        S_IDLE: begin
          pos_row <= 0;
          pos_col <= 0;
          if (start) begin
            state   <= S_TAP_SETUP;
            tap_idx <= 0;
          end
        end

        S_TAP_SETUP: begin
          // Prime x_valid so the first S_TAP_DRIVE cycle (tap_idx=0) is
          // sampled by the MAC engine. frame_buf + conv_window are pure
          // combinational, so pixel_in is already valid for tap_idx=0.
          x_valid <= 1'b1;
          tap_idx <= 4'd0;
          state   <= S_TAP_DRIVE;
        end

        S_TAP_DRIVE: begin
          // Hold x_valid high for all 9 taps while tap_idx counts 0..8.
          // pixel_in tracks tap_idx combinationally, so the engine sees
          // (w[0]*tap0, w[1]*tap1, ..., w[8]*tap8) in the correct order.
          x_valid <= 1'b1;
          if (tap_idx == 4'd8) begin
            x_valid <= 1'b0;   // 9th tap captured; deassert after
            state   <= S_WAIT_MAC;
          end else begin
            tap_idx <= tap_idx + 4'd1;
            state   <= S_TAP_DRIVE;
          end
        end

        S_WAIT_MAC: begin
          x_valid <= 1'b0;
          if (layer_done) begin
            state <= S_READOUT;
            f_idx <= 0;
            out_sel <= 0;
            ob_addr <= linear_pos * 14'd16;
            ob_we <= 1'b1;
          end
        end

        S_READOUT: begin
          // Hold the out_buf write-enable high for the whole 16-filter window.
          // Each cycle writes one ReLU'd accumulator to the next address.
          // (The blanket default-clear above would otherwise drop ob_we after
          //  the first cycle, so only mem[0] would ever be written.)
          ob_we   <= 1'b1;
          if (f_idx == N - 1) begin
            state <= S_NEXT_POS;
            ob_we <= 1'b0;   // deassert once the last filter is written
          end else begin
            f_idx   <= f_idx + 1;
            out_sel <= out_sel + 1;
            ob_addr <= ob_addr + 1;
          end
        end

        S_NEXT_POS: begin
          if (pos_col == OUT_C - 1) begin
            pos_col <= 0;
            if (pos_row == OUT_R - 1) begin
              state <= S_DONE;
            end else begin
              pos_row <= pos_row + 1;
              rearm   <= 1'b1;
              tap_idx <= 0;
              state   <= S_TAP_SETUP;
            end
          end else begin
            pos_col <= pos_col + 1;
            rearm   <= 1'b1;
            tap_idx <= 0;
            state   <= S_TAP_SETUP;
          end
        end

        S_DONE: begin
          if (!start) begin
            state <= S_IDLE;
          end
        end
        
        default: state <= S_IDLE;
      endcase
    end
  end

  // Sticky done (level, not a 1-clock pulse): a real host polls this via
  // SPI (STATUS busy bit / n_int) and cannot reliably catch a single-clock
  // pulse. Set when the sweep completes; cleared by reset or by the next
  // START (auto-acknowledge — the host has finished with this result).
  reg done_r;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      done_r <= 1'b0;
    else if (start)
      done_r <= 1'b0;
    else if (state == S_DONE)
      done_r <= 1'b1;
  end
  assign done = done_r;

endmodule
