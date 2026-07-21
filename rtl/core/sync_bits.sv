// sync_bits.sv
// M7 — level-signal / gray-vector synchronizer. STAGES flip-flops in the
// destination domain; q_dst taps the LAST stage only. Intended for gray-coded
// or otherwise sample-safe vectors (each bit may go metastable but the vector
// resolves to a legal old/new value). NOT for multi-bit binary buses.
// See docs/cdc_reset_contract.md. Metastability resolution is an ASSUMPTION.
`ifndef SYNC_BITS_SV
`define SYNC_BITS_SV
module sync_bits #(
  parameter int unsigned WIDTH  = 1,
  parameter int unsigned STAGES = 2
) (
  input  logic             clk_dst,
  input  logic             rst_dst_n,
  input  logic [WIDTH-1:0] d_src,       // free-running source-domain vector
  output logic [WIDTH-1:0] q_dst,       // = last stage
  output logic [STAGES*WIDTH-1:0] dbg_sync   // flat chain (stage0..stageN-1)
);
  logic [WIDTH-1:0] sync [STAGES];
  integer s;
  always_ff @(posedge clk_dst or negedge rst_dst_n) begin
    if (!rst_dst_n) begin
      for (s = 0; s < STAGES; s++) sync[s] <= '0;
    end else begin
      sync[0] <= d_src;
      for (s = 1; s < STAGES; s++) sync[s] <= sync[s-1];
    end
  end
  assign q_dst = sync[STAGES-1];
  genvar gs;
  generate for (gs = 0; gs < STAGES; gs++) begin : g_dbg_sync
    assign dbg_sync[gs*WIDTH +: WIDTH] = sync[gs];
  end endgenerate

`ifdef FORMAL
  // CDC hardening depth: at least a two-flop synchronizer. A reduced-stage
  // instantiation (metastability weakening) fails this at t=0.
  initial assert (STAGES >= 2);
`endif
endmodule
`endif
