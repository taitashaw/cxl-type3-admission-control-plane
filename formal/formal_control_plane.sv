// formal_control_plane.sv — free-input wrapper around control_plane_top. The
// system safety ASSERTS live in the DUT hierarchy under `ifdef FORMAL
// (config_ctrl: atomic snapshot commit / no-partial-update / freeze; control_plane:
// shared-commit equality / no credit reject / no live entry crosses commit;
// admission: conservation / all-fire / A2 / epoch; tracker + credit invariants).
// This wrapper supplies free stimulus and the COVER statements.
module formal_control_plane #(
  parameter int unsigned N_POOLS = 2,
  parameter int unsigned AMT_W   = 2,
  parameter int unsigned COUNT_W = 3,
  parameter int unsigned RESET_MAX= 2,
  parameter int unsigned DEPTH   = 2,
  parameter int unsigned GEN_W   = 2,
  parameter int unsigned EPOCH_W = 3,
  parameter int unsigned OP_W    = 1,
  parameter int unsigned META_W  = 3,
  parameter int unsigned TS_W    = 3,
  parameter int unsigned HDM_W   = 3,
  parameter int unsigned CAP_W   = 3,
  parameter int unsigned CREDIT_VEC_W = N_POOLS*AMT_W,
  parameter int unsigned MREQ_W  = COUNT_W+1,
  parameter int unsigned SLOT_W  = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  parameter int unsigned TAG_W   = GEN_W + SLOT_W,
  parameter int unsigned OCC_W   = SLOT_W + 1
)( input logic clk );
  logic rst_n;
  logic [TS_W-1:0] current_ts;
  logic cfg_req_valid, cfg_req_ready;
  logic [HDM_W-1:0] cfg_hdm_base, cfg_hdm_size;
  logic [CAP_W-1:0] cfg_capacity;
  logic cfg_timeout_en; logic [TS_W-1:0] cfg_timeout_thresh;
  logic [N_POOLS*MREQ_W-1:0] cfg_cmax; logic [EPOCH_W-1:0] cfg_epoch;
  logic cfg_rsp_valid, cfg_rsp_ready; logic [2:0] cfg_rsp_code, cfg_rsp_reason;
  logic req_valid; logic [OP_W-1:0] req_op; logic [META_W-1:0] req_meta;
  logic [CREDIT_VEC_W-1:0] req_credit_vec;
  logic req_ready, req_accept; logic [TAG_W-1:0] issued_tag;
  logic downstream_ready, issue_valid; logic [TAG_W-1:0] issue_tag;
  logic resp_valid; logic [TAG_W-1:0] resp_tag;
  logic resp_retire; logic [2:0] resp_class; logic [EPOCH_W-1:0] retired_epoch;
  logic reclaim_req_valid, reclaim_req_ready; logic [TAG_W-1:0] reclaim_tag;
  logic reclaim_rsp_valid, reclaim_rsp_ready; logic [TAG_W-1:0] reclaim_rsp_tag;
  logic [2:0] reclaim_rsp_class;
  logic global_cfg_commit_fire; logic [EPOCH_W-1:0] active_epoch;
  logic active_timeout_en; logic [TS_W-1:0] active_timeout_thresh;
  logic [HDM_W-1:0] active_hdm_base, active_hdm_size; logic [CAP_W-1:0] active_capacity;
  logic [N_POOLS*COUNT_W-1:0] used, available; logic [OCC_W-1:0] occupancy;

  control_plane_top #(.N_POOLS(N_POOLS), .AMT_W(AMT_W), .COUNT_W(COUNT_W), .RESET_MAX(RESET_MAX),
                      .DEPTH(DEPTH), .GEN_W(GEN_W), .EPOCH_W(EPOCH_W), .OP_W(OP_W),
                      .META_W(META_W), .TS_W(TS_W), .HDM_W(HDM_W), .CAP_W(CAP_W)) dut (.*);

  // hold reset 2 cycles (both sub-blocks reach a clean state), then free
  logic [1:0] f_rstc = 2'd0;
  always_ff @(posedge clk) if (f_rstc != 2'd3) f_rstc <= f_rstc + 2'd1;
  always_comb if (f_rstc < 2'd2) assume (!rst_n);
  logic p_rst; always_ff @(posedge clk) p_rst <= rst_n;

  always @(posedge clk) begin
    cover (rst_n && global_cfg_commit_fire);                                 // reached a shared commit
    cover (rst_n && cfg_rsp_valid && cfg_rsp_code == 3'd0);                   // OK response (post-commit)
    cover (rst_n && cfg_rsp_valid && cfg_rsp_code == 3'd1);                   // INVALID response
    cover (rst_n && cfg_rsp_valid && cfg_rsp_code == 3'd1 && !global_cfg_commit_fire); // invalid, no commit
    cover (rst_n && dut.u_cfg.state == 3'd1 && occupancy != '0);             // draining with live traffic
    cover (rst_n && req_accept && occupancy != '0);                          // admit while traffic live
    cover (rst_n && dut.quarantined_count != '0);                           // quarantine present
    cover (rst_n && global_cfg_commit_fire && p_rst);                        // commit after prior activity
    cover (rst_n && cfg_rsp_valid && !cfg_rsp_ready);                        // config response backpressure
    cover (rst_n && !req_accept && !dut.req_accept_enable && req_valid);     // admission blocked by config
    cover (!rst_n && p_rst);                                                 // reset with prior activity
  end

  generate if (DEPTH > 1) begin : g_multi
    always @(posedge clk)
      cover (rst_n && req_accept && resp_retire && dut.reclaim_commit_fire); // accept+retire+reclaim
  end endgenerate
endmodule
