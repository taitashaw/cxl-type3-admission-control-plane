// formal_reset_sync.sv — free-input wrapper around reset_sync. The safety
// asserts (async assert, synchronized deassert) live inside reset_sync's FORMAL
// block; this just exposes free inputs on a single destination clock.
module formal_reset_sync #(parameter int unsigned STAGES = 2)(
  input logic clk_dst
);
  logic arst_n_in, rst_dst_n_out;
  reset_sync #(.STAGES(STAGES)) dut (.*);
endmodule
