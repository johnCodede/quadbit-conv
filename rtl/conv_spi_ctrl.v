`default_nettype none

// conv_spi_ctrl.v — SPI command FSM tailored for Convolution flow
// 
// Decodes byte-framed SPI packets to load weights, load frames, and read outputs.
// Commands:
//   0x01 RESET
//   0x02 W_WRITE  k_hi k_lo n_hi n_lo w -> status (Load 9x16 weights)
//   0x03 W_LOCK   -> status
//   0x08 F_WRITE  row col val -> status (Load 28x28 frame pixels)
//   0x04 START    -> status (Triggers conv_ctrl spatial FSM)
//   0x06 O_READ   addr_hi addr_lo -> acc[23:16] acc[15:8] acc[7:0] (Read out_buf)
//   0x07 STATUS   -> status

module conv_spi_ctrl #(
  /* verilator lint_off UNUSEDPARAM */
  parameter K = 9, N = 16, IN_W = 8, ACC_W = 24
  /* verilator lint_on UNUSEDPARAM */
) (
  input  wire       clk,
  input  wire       cs_n,
  input  wire       sys_rst_n, // async active-low: defined power-on state
  input  wire [7:0] rx_data,
  input  wire       rx_valid,
  output wire [7:0] tx_data,

  output wire                  rst_n,
  
  // Weight programming (to quadbit_layer)
  output wire                  w_wr_en,
  output wire [$clog2(K)-1:0]  w_row,
  output wire [$clog2(N)-1:0]  w_col,
  output wire [1:0]            w_val,
  output wire                  lock,
  
  // Frame programming (to frame_buf)
  output wire                  f_we,
  output wire [4:0]            f_row,
  output wire [4:0]            f_col,
  output wire [7:0]            f_val,
  
  // Conv control (to conv_ctrl)
  output wire                  start,
  
  // Output buffer read (from out_buf)
  output wire [13:0]           ob_raddr,
  input  wire [ACC_W-1:0]      ob_rdata,
  
  // Status inputs
  input  wire [1:0]            eng_state,
  input  wire                  conv_done
);

  localparam [2:0] S_IDLE  = 3'd0;
  localparam [2:0] S_ARG   = 3'd1;
  localparam [2:0] S_EXEC  = 3'd2;
  localparam [2:0] S_REPLY = 3'd3;
  localparam [2:0] S_BEXEC = 3'd4;
  localparam [2:0] S_BREPLY= 3'd5;

  localparam OP_RESET    = 8'h01;
  localparam OP_W_WRITE  = 8'h02;
  localparam OP_W_LOCK   = 8'h03;
  localparam OP_START    = 8'h04;
  localparam OP_O_READ   = 8'h06;
  localparam OP_STATUS   = 8'h07;
  localparam OP_F_WRITE  = 8'h08;
  localparam OP_O_READ_BURST = 8'h09;

  reg [2:0] state;
  reg [7:0] opcode;
  reg [2:0] arg_cnt;
  reg [2:0] arg_expect;
  reg [7:0] arg0, arg1, arg2, arg3;
  
  reg [1:0] reply_cnt;
  reg [15:0] burst_left;
  reg [7:0] errcode_r;
  
  reg rst_n_r, w_wr_en_r, lock_r, f_we_r, start_r;
  reg [$clog2(K)-1:0] w_row_r;
  reg [$clog2(N)-1:0] w_col_r;
  reg [1:0] w_val_r;
  reg [4:0] f_row_r, f_col_r;
  reg [7:0] f_val_r;
  reg [13:0] ob_raddr_r;
  reg [ACC_W-1:0] acc_r;
  
  assign rst_n = rst_n_r;
  assign w_wr_en = w_wr_en_r;
  assign w_row = w_row_r;
  assign w_col = w_col_r;
  assign w_val = w_val_r;
  assign lock = lock_r;
  assign f_we = f_we_r;
  assign f_row = f_row_r;
  assign f_col = f_col_r;
  assign f_val = f_val_r;
  assign start = start_r;
  
  // Address space is 10816 (< 2^14); only the low 14 bits of the two
  // address bytes are meaningful. Size the wire to 14 bits for clean lint.
  wire [13:0] o_read_addr = {arg0[5:0], rx_data};
  assign ob_raddr = (state == S_ARG && arg_cnt == 3'd1 && opcode == OP_O_READ) ? 
                      o_read_addr     : ob_raddr_r;

  wire ready = (eng_state == 2'd0);
  wire locked = (eng_state == 2'd1);
  wire busy = !conv_done;
  
  wire [7:0] current_status = {
    (errcode_r != 8'h00), // ERROR
    ready,                // READY
    locked,               // LOCKED
    busy,                 // BUSY
    errcode_r[3:0]        // ERRCODE
  };

  assign tx_data = (state == S_REPLY || state == S_EXEC || state == S_BREPLY || state == S_BEXEC) ?
                     ((reply_cnt == 2'd0) ? acc_r[23:16] :
                      (reply_cnt == 2'd1) ? acc_r[15:8]  :
                                            acc_r[7:0]) :
                   current_status;

  reg rx_valid_d;
  
  /* verilator lint_off UNUSEDSIGNAL */
  wire [15:0] w_write_k = {arg0, arg1};
  wire [15:0] w_write_n = {arg2, arg3};
  /* verilator lint_on UNUSEDSIGNAL */

  always @(posedge clk or posedge cs_n or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
      state <= S_IDLE;
      errcode_r <= 8'h00;
      rst_n_r <= 1'b1;
      w_wr_en_r <= 1'b0;
      lock_r <= 1'b0;
      f_we_r <= 1'b0;
      start_r <= 1'b0;
      rx_valid_d <= 1'b0;
      reply_cnt <= 2'd0;
      ob_raddr_r <= 14'd0;
      acc_r <= {ACC_W{1'b0}};
      arg_cnt <= 3'd0;
      arg_expect <= 3'd0;
      opcode <= 8'h00;
      w_row_r <= 0;
      w_col_r <= 0;
      w_val_r <= 2'b00;
      f_row_r <= 5'd0;
      f_col_r <= 5'd0;
      f_val_r <= 8'h00;
      burst_left <= 16'd0;
    end else if (cs_n) begin
      state <= S_IDLE;
      errcode_r <= 8'h00;
      rst_n_r <= 1'b1;
      w_wr_en_r <= 1'b0;
      lock_r <= 1'b0;
      f_we_r <= 1'b0;
      start_r <= 1'b0;
      rx_valid_d <= 1'b0;
      reply_cnt <= 2'd0;
      ob_raddr_r <= 14'd0;
      acc_r <= {ACC_W{1'b0}};
      arg_cnt <= 3'd0;
      arg_expect <= 3'd0;
      opcode <= 8'h00;
      w_row_r <= 0;
      w_col_r <= 0;
      w_val_r <= 2'b00;
      f_row_r <= 5'd0;
      f_col_r <= 5'd0;
      f_val_r <= 8'h00;
      burst_left <= 16'd0;
    end else begin
      rx_valid_d <= rx_valid;
      rst_n_r <= 1'b1;
      w_wr_en_r <= 1'b0;
      lock_r <= 1'b0;
      f_we_r <= 1'b0;
      start_r <= 1'b0;
      
      if (rx_valid && !rx_valid_d) begin
        case (state)
          S_IDLE: begin
            opcode <= rx_data;
            errcode_r <= 8'h00;
            reply_cnt <= 2'd0;
            if (rx_data == OP_RESET) begin
              rst_n_r <= 1'b0; state <= S_IDLE;
            end else if (rx_data == OP_W_WRITE) begin
              arg_expect <= 3'd5; arg_cnt <= 3'd0; state <= S_ARG;
            end else if (rx_data == OP_W_LOCK) begin
              lock_r <= 1'b1; state <= S_IDLE;
            end else if (rx_data == OP_F_WRITE) begin
              arg_expect <= 3'd3; arg_cnt <= 3'd0; state <= S_ARG;
            end else if (rx_data == OP_START) begin
              if (!locked) errcode_r <= 8'h01;
              else start_r <= 1'b1;
              state <= S_IDLE;
            end else if (rx_data == OP_O_READ) begin
              arg_expect <= 3'd2; arg_cnt <= 3'd0; state <= S_ARG;
            end else if (rx_data == OP_O_READ_BURST) begin
              arg_expect <= 3'd4; arg_cnt <= 3'd0; state <= S_ARG;
            end else if (rx_data == OP_STATUS) begin
              state <= S_IDLE;
            end else begin
              errcode_r <= 8'h03; state <= S_IDLE;
            end
          end
          S_ARG: begin
            case (arg_cnt)
              3'd0: arg0 <= rx_data;
              3'd1: begin
                arg1 <= rx_data;
                if (opcode == OP_O_READ_BURST) ob_raddr_r <= {arg0[5:0], rx_data};
              end
              3'd2: arg2 <= rx_data;
              3'd3: arg3 <= rx_data;
              default: ;
            endcase
            if (arg_cnt + 3'd1 == arg_expect) begin
              if (opcode == OP_W_WRITE) begin
                w_row_r <= w_write_k[$clog2(K)-1:0];
                w_col_r <= w_write_n[$clog2(N)-1:0];
                w_val_r <= rx_data[1:0];
                w_wr_en_r <= 1'b1;
                state <= S_IDLE;
              end else if (opcode == OP_F_WRITE) begin
                f_row_r <= arg0[4:0];
                f_col_r <= arg1[4:0];
                f_val_r <= rx_data;
                f_we_r <= 1'b1;
                state <= S_IDLE;
              end else if (opcode == OP_O_READ) begin
                ob_raddr_r <= o_read_addr;
                state <= S_EXEC;
              end else if (opcode == OP_O_READ_BURST) begin
                burst_left <= {arg2, rx_data};
                state <= S_BEXEC;
              end
            end else begin
              arg_cnt <= arg_cnt + 3'd1;
            end
          end
          S_REPLY: begin
            if (reply_cnt == 2'd2) state <= S_IDLE;
            else reply_cnt <= reply_cnt + 2'd1;
          end
          S_BREPLY: begin
            if (reply_cnt == 2'd2) begin
              if (burst_left == 16'd1 || burst_left == 16'd0) begin
                state <= S_IDLE;
              end else begin
                burst_left <= burst_left - 16'd1;
                state <= S_BEXEC;
                reply_cnt <= 2'd0;
              end
            end else begin
              reply_cnt <= reply_cnt + 2'd1;
            end
          end
          default: state <= S_IDLE;
        endcase
      end else if (state == S_EXEC) begin
        acc_r <= ob_rdata;
        state <= S_REPLY;
      end else if (state == S_BEXEC) begin
        acc_r <= ob_rdata;
        ob_raddr_r <= ob_raddr_r + 14'd1;
        state <= S_BREPLY;
      end
    end
  end
endmodule
