// formal_tracker.sv — small-parameter free-input wrapper around
// outstanding_tracker. Safety ASSERTS live in the DUT under `ifdef FORMAL; this
// wrapper supplies free stimulus and the COVER statements proving non-vacuity.
// Reset: initial assume(!rst_n); rst_n free afterwards (asserts & deasserts).
module formal_tracker #(
  parameter int unsigned DEPTH   = 3,     // non-power-of-two
  parameter int unsigned GEN_W   = 2,
  parameter int unsigned EPOCH_W = 4,
  parameter int unsigned OP_W    = 1,
  parameter int unsigned META_W  = 4,
  parameter int unsigned TS_W    = 4,
  parameter int unsigned SLOT_W  = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  parameter int unsigned TAG_W   = GEN_W + SLOT_W,
  parameter int unsigned OCC_W   = SLOT_W + 1
)(
  input logic clk
);
  localparam logic [2:0] RC_STALE_GEN = 3;

  logic               rst_n;
  logic [TS_W-1:0]    current_ts, timeout_thresh;
  logic               timeout_enable;
  logic               alloc_req;
  logic [EPOCH_W-1:0] alloc_epoch;
  logic [OP_W-1:0]    alloc_op;
  logic [META_W-1:0]  alloc_meta;
  logic               alloc_gnt, full;
  logic [TAG_W-1:0]   alloc_tag;
  logic [SLOT_W-1:0]  alloc_slot;
  logic               resp_valid, resp_retire;
  logic [TAG_W-1:0]   resp_tag;
  logic [2:0]         resp_class;
  logic [EPOCH_W-1:0] retired_epoch;
  logic [OP_W-1:0]    retired_op;
  logic [META_W-1:0]  retired_meta;
  logic               reclaim_req, reclaim_done;
  logic [TAG_W-1:0]   reclaim_tag;
  logic [2:0]         reclaim_class;
  logic [OCC_W-1:0]   occupancy, high_watermark, quarantined_count;
  logic               timeout_any, err_sticky;
  logic [2:0]         err_first_class;
  logic [31:0]        alloc_count, retire_count, full_count, timeout_count, reclaim_count,
                      invalid_slot_count, non_live_count, stale_gen_count;

  outstanding_tracker #(.DEPTH(DEPTH), .GEN_W(GEN_W), .EPOCH_W(EPOCH_W),
                        .OP_W(OP_W), .META_W(META_W), .TS_W(TS_W)) dut (.*);

  initial assume (!rst_n);
  logic [OCC_W-1:0] p_occ; logic p_rst;
  always_ff @(posedge clk) begin p_occ <= occupancy; p_rst <= rst_n; end

  always @(posedge clk) begin
    cover (rst_n && alloc_gnt);                                  // allocation
    cover (rst_n && full);                                       // full boundary
    cover (rst_n && resp_retire);                                // valid retirement
    cover (rst_n && resp_valid && resp_class == RC_STALE_GEN);   // stale-generation response
    cover (rst_n && timeout_any);                                // timeout reached
    cover (rst_n && occupancy == OCC_W'(DEPTH));                 // fully occupied
    cover (rst_n && reclaim_done);                               // reclaim of a quarantined slot
    cover (rst_n && quarantined_count != '0);                    // a slot is quarantined
    cover (!rst_n && p_occ != 0);                                // reset with live entries
    cover (p_rst == 1'b0 && rst_n == 1'b1);                      // reset deasserts
  end

  // simultaneous alloc+retire is only reachable for DEPTH>1 (a single slot
  // cannot be reused the same cycle it retires — no forwarding, by design).
  generate if (DEPTH > 1) begin : g_simul
    always @(posedge clk) cover (rst_n && alloc_gnt && resp_retire);
  end endgenerate
endmodule
