`default_nettype none

// quadbit_conv_top.v - Top level wrapper for the Convolution Coprocessor
// 
// Combines:
// - spi_slave: SPI Mode 0 byte-framed transport
// - conv_spi_ctrl: SPI command FSM and decoding for convolution
// - frame_buf: 28x28x8 SRAM for the input image
// - conv_window: 3x3 sliding window address generator
// - quadbit_layer: Dense layer math engine reused as K=9, N=16 MAC array
// - conv_ctrl: Spatial FSM that iterates over the 26x26 grid
// - out_buf: 26x26x16 result buffer for the feature map

module quadbit_conv_top #(
  parameter K = 9,       // 3x3 Window = 9 taps
  parameter N = 16,      // 16 filters per conv pass
  parameter IN_W = 8,
  parameter ACC_W = 24
) (
  input  wire sys_clk,
  input  wire sys_rst_n,

  // SPI Interface (Mode 0)
  input  wire spi_sclk,
  input  wire spi_cs_n,
  input  wire spi_mosi,
  output wire spi_miso,

  output wire n_ready,
  output wire n_int
);

  wire soft_rst_n;
  wire layer_rst_n = sys_rst_n & soft_rst_n;
  
  wire [7:0] rx_data, tx_data;
  wire rx_valid;
  
  spi_slave u_spi (
    .sclk(spi_sclk), .cs_n(spi_cs_n), .mosi(spi_mosi), .miso(spi_miso),
    .rst_n(sys_rst_n),
    .rx_data(rx_data), .rx_valid(rx_valid), .tx_data(tx_data)
  );

  wire w_wr_en, lock, f_we, start, conv_done;
  wire [$clog2(K)-1:0] w_row;
  wire [$clog2(N)-1:0] w_col;
  wire [1:0] w_val;
  wire [4:0] f_row, f_col;
  wire [7:0] f_val;
  wire [13:0] ob_raddr;
  wire [ACC_W-1:0] ob_rdata;
  wire [1:0] eng_state;
  
  conv_spi_ctrl #(
    .K(K), .N(N), .IN_W(IN_W), .ACC_W(ACC_W)
  ) u_ctrl (
    .clk(sys_clk), .cs_n(spi_cs_n), .sys_rst_n(sys_rst_n),
    .rx_data(rx_data), .rx_valid(rx_valid), .tx_data(tx_data),
    .rst_n(soft_rst_n),
    .w_wr_en(w_wr_en), .w_row(w_row), .w_col(w_col), .w_val(w_val), .lock(lock),
    .f_we(f_we), .f_row(f_row), .f_col(f_col), .f_val(f_val),
    .start(start), .conv_done(conv_done),
    .ob_raddr(ob_raddr), .ob_rdata(ob_rdata),
    .eng_state(eng_state)
  );

  wire [4:0] win_r_row, win_r_col;
  wire [7:0] win_r_data;
  
  frame_buf #(
    .ROWS(28), .COLS(28), .DATA_W(8)
  ) u_fbuf (
    .clk(sys_clk), .rst_n(layer_rst_n),
    .w_en(f_we), .w_row(f_row), .w_col(f_col), .w_data(f_val),
    .r_row(win_r_row), .r_col(win_r_col), .r_data(win_r_data),
    /* verilator lint_off PINCONNECTEMPTY */
    .frame_full()
    /* verilator lint_on PINCONNECTEMPTY */
  );
  
  wire [4:0] pos_row, pos_col;
  wire [3:0] tap_idx;
  wire [7:0] pixel_in;
  
  conv_window #(
    .ROWS(28), .COLS(28), .DATA_W(8)
  ) u_win (
    .pos_row(pos_row), .pos_col(pos_col), .tap_idx(tap_idx),
    .r_row(win_r_row), .r_col(win_r_col), .r_data(win_r_data),
    .pixel_out(pixel_in)
  );
  
  wire x_valid, rearm, layer_done;
  wire [7:0] x_data;
  wire [$clog2(N)-1:0] out_sel;
  wire [ACC_W-1:0] layer_out;
  
  quadbit_layer #(
    .K(K), .N(N), .IN_W(IN_W), .ACC_W(ACC_W)
  ) u_layer (
    .clk(sys_clk), .rst_n(layer_rst_n),
    .w_wr_en(w_wr_en), .w_row(w_row), .w_col(w_col), .w_val(w_val),
    .k_en_set(1'b1), .k_en_val({K{1'b1}}),
    .n_en_set(1'b1), .n_en_val({N{1'b1}}),
    .lock(lock),
    .x_valid(x_valid), .x_data(x_data),
    .rearm(rearm),
    .out_sel(out_sel), .out_data(layer_out),
    /* verilator lint_off PINCONNECTEMPTY */
    .ctrl_evt(), .state(eng_state), .done(layer_done)
    /* verilator lint_on PINCONNECTEMPTY */
  );
  
  wire ob_we;
  wire [13:0] ob_addr;
  wire [ACC_W-1:0] ob_wdata;
  
  conv_ctrl #(
    .ROWS(28), .COLS(28), .OUT_R(26), .OUT_C(26),
    .N(N), .DATA_W(8), .ACC_W(ACC_W)
  ) u_conv (
    .clk(sys_clk), .rst_n(layer_rst_n),
    .start(start), .done(conv_done),
    .pos_row(pos_row), .pos_col(pos_col), .tap_idx(tap_idx), .pixel_in(pixel_in),
    .x_valid(x_valid), .x_data(x_data), .rearm(rearm),
    .out_sel(out_sel), .layer_out(layer_out),
    .layer_state(eng_state), .layer_done(layer_done),
    .ob_we(ob_we), .ob_addr(ob_addr), .ob_data(ob_wdata)
  );
  
  out_buf #(
    .DEPTH(10816), .DATA_W(ACC_W)
  ) u_obuf (
    .clk(sys_clk),
    .w_en(ob_we), .w_addr(ob_addr), .w_data(ob_wdata),
    .r_addr(ob_raddr), .r_data(ob_rdata)
  );
  
  // Status mapping
  // eng_state 1 = S_READY in quadbit_layer.v
  assign n_ready = ~(eng_state == 2'd1);
  assign n_int   = ~conv_done;
  
endmodule
