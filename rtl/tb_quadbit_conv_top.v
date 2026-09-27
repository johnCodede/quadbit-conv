`default_nettype none
`timescale 1ns/1ps

module tb_quadbit_conv_top;

  localparam K = 9;
  localparam N = 16;
  localparam IN_W = 8;
  localparam ACC_W = 24;
  localparam ROWS = 28;
  localparam COLS = 28;

  reg sys_clk;
  reg sys_rst_n;

  reg spi_sclk;
  reg spi_cs_n;
  reg spi_mosi;
  wire spi_miso;

  wire n_ready;
  wire n_int;

  quadbit_conv_top #(
    .K(K), .N(N), .IN_W(IN_W), .ACC_W(ACC_W)
  ) dut (
    .sys_clk(sys_clk), .sys_rst_n(sys_rst_n),
    .spi_sclk(spi_sclk), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
    .n_ready(n_ready), .n_int(n_int)
  );

  always #5 sys_clk = ~sys_clk;

  task spi_write(input [7:0] d);
    integer i;
    begin
      for (i = 7; i >= 0; i = i - 1) begin
        spi_mosi = d[i];
        #20 spi_sclk = 1;
        #20 spi_sclk = 0;
      end
      #10;
    end
  endtask

  task spi_read(output [7:0] d);
    integer i;
    begin
      d = 0;
      for (i = 7; i >= 0; i = i - 1) begin
        spi_mosi = 0;
        #20 spi_sclk = 1;
        d[i] = spi_miso;
        #20 spi_sclk = 0;
      end
      #10;
    end
  endtask

  integer r, c, t, f, w, v, errors;
  reg [7:0] b0, b1, b2;
  reg [23:0] val;
  reg [31:0] total_sum;

  initial begin
    sys_clk = 0; sys_rst_n = 0;
    spi_sclk = 0; spi_cs_n = 1; spi_mosi = 0;
    errors = 0; total_sum = 0;

    #50 sys_rst_n = 1;
    #50;

    // Load Weights
    $display("Loading 9x16 weights...");
    for (t = 0; t < 9; t = t + 1) begin
      for (f = 0; f < 16; f = f + 1) begin
        w = (t + f) % 3;
        if (w == 2) v = 2;       // 10
        else if (w == 1) v = 0;  // 00
        else v = 1;              // 01
        
        spi_cs_n = 1; #10;
        spi_cs_n = 0; // START TRANSACTION
        spi_write(8'h02); // W_WRITE
        spi_write(8'h00); spi_write(t[7:0]); 
        spi_write(8'h00); spi_write(f[7:0]); 
        spi_write(v[7:0]);
        spi_cs_n = 1; #10;
      end
    end

    // Lock Weights
    spi_cs_n = 1; #10;
    spi_cs_n = 0; // START TRANSACTION
    spi_write(8'h03);
    spi_cs_n = 1; #10;

    // Load Frame
    $display("Loading 28x28 frame...");
    for (r = 0; r < 28; r = r + 1) begin
      for (c = 0; c < 28; c = c + 1) begin
        v = (r * 28 + c) & 8'hFF;
        spi_cs_n = 1; #10;
        spi_cs_n = 0; // START TRANSACTION
        spi_write(8'h08); // F_WRITE
        spi_write(r[7:0]);
        spi_write(c[7:0]);
        spi_write(v[7:0]);
        spi_cs_n = 1; #10;
      end
    end

    // Start Conv
    $display("Starting Convolution...");
    spi_cs_n = 1; #10;
    spi_cs_n = 0; // START TRANSACTION
    spi_write(8'h04);
    spi_cs_n = 1; #10;

    wait(n_int == 0); // Wait for done
    // STICKY-DONE contract: n_int must remain Low *after* the completion
    // edge. A 1-cycle done pulse would have re-asserted n_int by now
    // (several sys_clk later), so this directly distinguishes the latch
    // from the old pulse. (wait() alone would catch either.)
    #50;
    if (n_int !== 1'b0) begin
      $display("FAIL: n_int not sticky (re-asserted after done) — pulse, not latch");
      errors = errors + 1;
    end
    $display("Convolution done. Reading outputs...");

    // Read and verify
    for (r = 0; r < 26; r = r + 1) begin
      for (c = 0; c < 26; c = c + 1) begin
        for (f = 0; f < 16; f = f + 1) begin
          v = r * 26 * 16 + c * 16 + f;
          
          spi_cs_n = 1; #10;
          spi_cs_n = 0; // START TRANSACTION
          spi_write(8'h06); // O_READ
          spi_write(v[15:8]);
          spi_write(v[7:0]);
          spi_read(b0); spi_read(b1); spi_read(b2);
          spi_cs_n = 1; #10;
          
          val = {b0, b1, b2};
          total_sum = total_sum + val;
          
          if (r == 0 && c == 0 && f == 0 && val !== 30) begin
             $display("FAIL: out[0,0,0] = %0d (expected 30)", val); errors = errors + 1;
          end
          if (r == 1 && c == 1 && f == 1 && val !== 0) begin
             $display("FAIL: out[1,1,1] = %0d (expected 0)", val); errors = errors + 1;
          end
          if (r == 25 && c == 25 && f == 15 && val !== 6) begin
             $display("FAIL: out[25,25,15] = %0d (expected 6)", val); errors = errors + 1;
          end
        end
      end
    end

    if (total_sum !== 96294) begin
      $display("FAIL: Total Sum = %0d (expected 96294)", total_sum);
      errors = errors + 1;
    end

    if (errors == 0) $display("=== ALL TESTS PASSED ===");
    else $display("=== %0d ERRORS ===", errors);
    
    $finish;
  end
endmodule
