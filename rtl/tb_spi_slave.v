`default_nettype none
module tb_spi_slave;

  reg  sclk=0, cs_n=1, mosi=0;
  wire miso;
  wire [7:0] rx_data;
  wire       rx_valid;
  reg  [7:0] tx_data;
  reg  clk_master=0;
  integer    errors=0;

  spi_slave dut(.sclk(sclk),.cs_n(cs_n),.mosi(mosi),.miso(miso),
                .rx_data(rx_data),.rx_valid(rx_valid),.tx_data(tx_data));

  always #5 clk_master = ~clk_master;

  initial begin
    tx_data = 8'h00;
    repeat(2) @(negedge clk_master);

    // ---- Test 1: single byte (MSI=0xA5, expect MISO=0x3C) ----
    tx_data = 8'h3C;
    cs_n = 0;
    @(negedge clk_master);

    // 8 bits MSB-first of 0xA5 = 10100101
    mosi=1; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=1; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=1; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=1; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);

    $display("t=%0t T1: rx=%h (expect A5)", $time, rx_data);
    if (rx_data !== 8'hA5) begin $display("FAIL T1 rx"); errors=errors+1; end
    else $display("PASS T1 rx");
    cs_n=1;
    repeat(2) @(negedge clk_master);

    // ---- Test 2: two bytes (MSI=0x12,0x34, expect MISO=0x56,0x78) ----
    tx_data = 8'h56;
    cs_n = 0;
    @(negedge clk_master);
    // byte 1: 0x12 = 00010010
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=1; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=1; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    $display("t=%0t T2 byte1: rx=%h (expect 12)", $time, rx_data);
    if (rx_data !== 8'h12) begin $display("FAIL T2 byte1 rx"); errors=errors+1; end
    else $display("PASS T2 byte1 rx");

    tx_data = 8'h78;
    @(negedge clk_master);
    // byte 2: 0x34 = 00110100
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=1; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=1; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=1; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    mosi=0; sclk=1; @(negedge clk_master); sclk=0; @(negedge clk_master);
    $display("t=%0t T2 byte2: rx=%h (expect 34)", $time, rx_data);
    if (rx_data !== 8'h34) begin $display("FAIL T2 byte2 rx"); errors=errors+1; end
    else $display("PASS T2 byte2 rx");
    cs_n=1;
    repeat(2) @(negedge clk_master);

    if (errors==0) $display("=== ALL SPI SLAVE TESTS PASSED ===");
    else           $display("=== %0d FAILED ===", errors);
    $finish;
  end

endmodule
