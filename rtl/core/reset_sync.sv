// reset_sync.sv
// M7 — async-assert / sync-deassert reset bridge. Assertion is immediate
// (async, on arst_n_in falling); deassertion is synchronized through STAGES
// flops so the destination domain leaves reset cleanly. See docs/cdc_reset_contract.md.
`ifndef RESET_SYNC_SV
`define RESET_SYNC_SV
module reset_sync #(
  parameter int unsigned STAGES = 2
) (
  input  logic clk_dst,
  input  logic arst_n_in,        // async reset in (any domain / POR)
  output logic rst_dst_n_out     // async assert, synchronized deassert
);
  logic [STAGES-1:0] sr;
  always_ff @(posedge clk_dst or negedge arst_n_in) begin
    if (!arst_n_in) sr <= '0;                          // async assert
    else            sr <= {sr[STAGES-2:0], 1'b1};      // shift 1s in on deassert
  end
  assign rst_dst_n_out = sr[STAGES-1];

`ifdef FORMAL
  initial assert (STAGES >= 2);
  logic f_init; initial f_init = 1'b0;
  always_ff @(posedge clk_dst) f_init <= 1'b1;
  always @(posedge clk_dst) begin
    // async assert: the moment arst_n_in is low, the output is low
    if (!arst_n_in) assert (rst_dst_n_out == 1'b0);
    // sync deassert: output cannot rise the same edge arst_n_in releases
    if (f_init && $past(!arst_n_in) && arst_n_in) assert (rst_dst_n_out == 1'b0);
  end
`endif
endmodule
`endif
