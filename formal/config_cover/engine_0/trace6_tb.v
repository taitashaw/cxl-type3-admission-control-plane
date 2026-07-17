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
    // UUT.$auto$async2sync.\cc:107:execute$1192  = 1'b0;
    // UUT.$auto$async2sync.\cc:116:execute$1154  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1160  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1166  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1172  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1178  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1184  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1190  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1196  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1202  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1208  = 1'b1;
    // UUT.$auto$async2sync.\cc:116:execute$1214  = 1'b1;
    UUT.dut._witness_.anyinit_procdff_756 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_761 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_766 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_771 = 4'b0000;
    UUT.dut._witness_.anyinit_procdff_776 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_781 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_786 = 13'b0000000000000;
    UUT.dut._witness_.anyinit_procdff_791 = 13'b0000000000000;
    UUT.dut._witness_.anyinit_procdff_796 = 13'b0000000000000;
    UUT.dut._witness_.anyinit_procdff_801 = 2'b00;
    UUT.dut._witness_.anyinit_procdff_811 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_816 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_821 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_826 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_831 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_836 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_841 = 12'b000000000000;
    UUT.dut._witness_.anyinit_procdff_846 = 12'b000000000000;
    UUT.dut._witness_.anyinit_procdff_851 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_856 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_861 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_866 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_871 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_876 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_881 = 12'b000000000000;
    UUT.dut._witness_.anyinit_procdff_886 = 12'b000000000000;
    UUT.dut._witness_.anyinit_procdff_891 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_896 = 1'b0;
    UUT.dut._witness_.anyinit_procdff_901 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_906 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_911 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_916 = 16'b0000000000000000;
    UUT.dut._witness_.anyinit_procdff_921 = 12'b000000000000;
    UUT.dut._witness_.anyinit_procdff_926 = 12'b000000000000;
    UUT.p_rst_n = 1'b0;
    UUT.p_state = 2'b00;

    // state 0
  end
  always @(posedge clock) begin
    // state 1
    if (cycle == 0) begin
    end

    // state 2
    if (cycle == 1) begin
    end

    // state 3
    if (cycle == 2) begin
    end

    genclock <= cycle < 3;
    cycle <= cycle + 1;
  end
endmodule
