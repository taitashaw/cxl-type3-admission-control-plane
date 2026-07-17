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
  formal_config UUT (
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
    // UUT.$auto$async2sync.\cc:107:execute$1054  = 1'b0;
    // UUT.$auto$async2sync.\cc:116:execute$1016  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1022  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1028  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1034  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1040  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1046  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1052  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1058  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1064  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1070  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1076  = 1'b1;
    UUT.dut._witness_.anyinit_procdff_675 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_680 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_685 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_690 = 4'b0000;
    UUT.dut._witness_.anyinit_procdff_695 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_700 = 13'b0000000000000;
    UUT.dut._witness_.anyinit_procdff_705 = 13'b0000000000000;
    UUT.dut._witness_.anyinit_procdff_710 = 13'b0000000000000;
    UUT.dut._witness_.anyinit_procdff_715 = 2'b00;
    UUT.dut._witness_.anyinit_procdff_725 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_730 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_735 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_740 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_745 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_750 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_755 = 12'b000000000000;
    UUT.dut._witness_.anyinit_procdff_760 = 12'b000000000000;
    UUT.dut._witness_.anyinit_procdff_765 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_770 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_775 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_780 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_785 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_790 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_795 = 12'b000000000000;
    UUT.dut._witness_.anyinit_procdff_800 = 12'b000000000000;
    UUT.dut._witness_.anyinit_procdff_805 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_810 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_815 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_820 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_825 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_830 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_835 = 12'b000000000000;
    UUT.dut._witness_.anyinit_procdff_840 = 12'b000000000000;
    UUT.p_rst_n = 1'b0;
    UUT.p_state = 2'b01;

    // state 0
  end
  always @(posedge clock) begin
    // state 1
    if (cycle == 0) begin
    end

    genclock <= cycle < 1;
    cycle <= cycle + 1;
  end
endmodule
