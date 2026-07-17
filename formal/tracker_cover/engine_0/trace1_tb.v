`ifndef VERILATOR
module testbench;
  reg [4095:0] vcdfile;
  reg clock;
`else
module testbench(input clock, output reg genclock);
  initial genclock = 1;
`endif
  reg genclock = 1;
  reg [31:0] cycle = 0;
  wire [0:0] PI_clk = clock;
  formal_tracker UUT (
    .clk(PI_clk)
  );
`ifndef VERILATOR
  initial begin
    if ($value$plusargs("vcd=%s", vcdfile)) begin
      $dumpfile(vcdfile);
      $dumpvars(0, testbench);
    end
    #5 clock = 0;
    while (genclock) begin
      #5 clock = 0;
      #5 clock = 1;
    end
  end
`endif
  initial begin
`ifndef VERILATOR
    #1;
`endif
    // UUT.$auto$async2sync.\cc:107:execute$1800  = 1'b0;
    // UUT.$auto$async2sync.\cc:116:execute$1774  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1780  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1786  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1792  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1798  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1804  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1810  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1816  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1822  = 1'b1;
    UUT.dut._witness_.anyinit_procdff_1351 = 3'b000;
    UUT.dut._witness_.anyinit_procdff_1356 = 3'b000;
    UUT.dut._witness_.anyinit_procdff_1361 = 32'b00000000000000000000000000000000;
    UUT.dut._witness_.anyinit_procdff_1366 = 32'b00000000000000000000000000000000;
    UUT.dut._witness_.anyinit_procdff_1371 = 32'b00000000000000000000000000000000;
    UUT.dut._witness_.anyinit_procdff_1376 = 32'b00000000000000000000000000000000;
    UUT.dut._witness_.anyinit_procdff_1381 = 32'b00000000000000000000000000000000;
    UUT.dut._witness_.anyinit_procdff_1386 = 32'b00000000000000000000000000000000;
    UUT.dut._witness_.anyinit_procdff_1391 = 32'b00000000000000000000000000000000;
    UUT.dut._witness_.anyinit_procdff_1396 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_1401 = 3'b000;
    UUT.dut._witness_.anyinit_procdff_1406 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_1411 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_1416 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_1421 = 2'b00;
    UUT.dut._witness_.anyinit_procdff_1426 = 2'b00;
    UUT.dut._witness_.anyinit_procdff_1431 = 2'b00;
    UUT.dut._witness_.anyinit_procdff_1436 = 4'b0000;
    UUT.dut._witness_.anyinit_procdff_1441 = 4'b0000;
    UUT.dut._witness_.anyinit_procdff_1446 = 4'b0000;
    UUT.dut._witness_.anyinit_procdff_1451 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_1456 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_1461 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_1466 = 4'b0000;
    UUT.dut._witness_.anyinit_procdff_1471 = 4'b0000;
    UUT.dut._witness_.anyinit_procdff_1476 = 4'b0000;
    UUT.dut._witness_.anyinit_procdff_1481 = 4'b0000;
    UUT.dut._witness_.anyinit_procdff_1486 = 4'b0000;
    UUT.dut._witness_.anyinit_procdff_1491 = 4'b0000;
    UUT.dut._witness_.anyinit_procdff_1496 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_1501 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_1506 = 1'b0;
    UUT.p_occ = 3'b000;
    UUT.p_rst = 1'b0;

    // state 0
  end
  always @(posedge clock) begin
    // state 1
    if (cycle == 0) begin
    end

    // state 2
    if (cycle == 1) begin
    end

    genclock <= cycle < 2;
    cycle <= cycle + 1;
  end
endmodule
