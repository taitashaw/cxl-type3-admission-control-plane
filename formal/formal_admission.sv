// formal_admission.sv — free-input wrapper around admission_top. Integration
// safety ASSERTS (all-fire-together, A2 theorem, return-never-rejected, credit
// conservation) live in the DUT under `ifdef FORMAL; the tracker's and credit
// manager's own `ifdef FORMAL invariants compile in too and act as strengthening
// lemmas. This wrapper supplies free stimulus and the COVER statements.
module formal_admission #(
  parameter int unsigned N_POOLS   = 2,
  parameter int unsigned AMT_W     = 2,
  parameter int unsigned COUNT_W   = 3,
  parameter int unsigned RESET_MAX = 2,
  parameter int unsigned DEPTH     = 2,
  parameter int unsigned GEN_W     = 2,
  parameter int unsigned EPOCH_W   = 3,
  parameter int unsigned OP_W      = 1,
  parameter int unsigned META_W    = 3,
  parameter int unsigned TS_W      = 3,
  parameter int unsigned CREDIT_VEC_W = N_POOLS*AMT_W,
  parameter int unsigned SLOT_W    = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  parameter int unsigned TAG_W     = GEN_W + SLOT_W,
  parameter int unsigned OCC_W     = SLOT_W + 1
)(
  input logic clk
);
  logic                   rst_n;
  logic [TS_W-1:0]        current_ts, timeout_thresh;
  logic                   timeout_enable;
  logic [EPOCH_W-1:0]     active_epoch;
  logic                   req_valid, req_accept_enable;
  logic [OP_W-1:0]        req_op;
  logic [META_W-1:0]      req_meta;
  logic [CREDIT_VEC_W-1:0] req_credit_vec;
  logic                   req_ready, req_accept;
  logic [TAG_W-1:0]       issued_tag;
  logic                   downstream_ready, issue_valid;
  logic [TAG_W-1:0]       issue_tag;
  logic                   resp_valid; logic [TAG_W-1:0] resp_tag;
  logic                   resp_retire; logic [2:0] resp_class;
  logic [EPOCH_W-1:0]     retired_epoch;
  logic                   reclaim_req_valid, reclaim_req_ready;
  logic [TAG_W-1:0]       reclaim_tag;
  logic                   reclaim_rsp_valid, reclaim_rsp_ready;
  logic [TAG_W-1:0]       reclaim_rsp_tag; logic [2:0] reclaim_rsp_class;
  logic                   tracker_alloc_fire, credit_consume_fire, issue_enqueue;
  logic                   credit_return_valid, credit_return_accepted;
  logic [N_POOLS*COUNT_W-1:0] used, available;
  logic [OCC_W-1:0]       occupancy;

  admission_top #(.N_POOLS(N_POOLS), .AMT_W(AMT_W), .COUNT_W(COUNT_W), .RESET_MAX(RESET_MAX),
                  .DEPTH(DEPTH), .GEN_W(GEN_W), .EPOCH_W(EPOCH_W), .OP_W(OP_W),
                  .META_W(META_W), .TS_W(TS_W)) dut (.*);

  // Reset environment: hold reset for the first 2 cycles (matches the TB's
  // multi-cycle reset) so both sub-modules reach a clean reset state before free
  // operation, then rst_n is free (asserts & deasserts).
  logic [1:0] f_rstc = 2'd0;
  always_ff @(posedge clk) if (f_rstc != 2'd3) f_rstc <= f_rstc + 2'd1;
  always_comb if (f_rstc < 2'd2) assume (!rst_n);
  logic p_rst; logic [OCC_W-1:0] p_occ;
  always_ff @(posedge clk) begin p_rst <= rst_n; p_occ <= occupancy; end

  always @(posedge clk) begin
    cover (rst_n && req_accept);                                              // ordinary admit
    cover (rst_n && tracker_alloc_fire && resp_retire);                       // alloc + retire same cycle
    cover (rst_n && tracker_alloc_fire && resp_retire && dut.reclaim_commit_fire); // alloc+retire+reclaim
    cover (rst_n && dut.retire_commit_fire && dut.reclaim_commit_fire);       // dual return
    cover (rst_n && credit_return_valid && credit_return_accepted);           // a credit return
    cover (rst_n && !req_accept_enable && req_valid);                         // A2 gate active with a request
    cover (rst_n && req_valid && req_accept_enable && dut.tracker_full);      // blocked by tracker full
    cover (rst_n && req_valid && req_accept_enable && !dut.credit_consume_ready); // blocked by credits
    cover (rst_n && req_valid && req_accept_enable && dut.issue_full_r);      // blocked by issue buffer
    cover (rst_n && reclaim_rsp_valid && !reclaim_rsp_ready);                 // reclaim response backpressure
    cover (!rst_n && p_occ != 0);                                            // reset with live entries
    cover (p_rst == 1'b0 && rst_n == 1'b1);                                  // reset deasserts
  end
endmodule
