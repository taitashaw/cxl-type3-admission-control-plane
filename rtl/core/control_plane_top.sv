// control_plane_top.sv
// M4 Phase 2c — the CXL Type-3 admission control plane: config_ctrl (atomic global
// configuration commit) + admission_top (tracker + credit_manager). One shared
// global_cfg_commit_fire updates the timeout policy, credit maxima, config epoch
// and HDM/capacity registers together; admission is frozen and fully drained first,
// so no live entry crosses a commit and credit conservation is preserved.
`ifndef CONTROL_PLANE_TOP_SV
`define CONTROL_PLANE_TOP_SV
// config_ctrl.sv, admission_top.sv, outstanding_tracker.sv, credit_manager.sv are
// provided by the ordered filelist — no textual includes.
module control_plane_top #(
  parameter int unsigned N_POOLS = 2,
  parameter int unsigned AMT_W   = 3,
  parameter int unsigned COUNT_W = 6,
  parameter int unsigned RESET_MAX= 8,
  parameter int unsigned DEPTH   = 4,
  parameter int unsigned GEN_W   = 4,
  parameter int unsigned EPOCH_W = 8,
  parameter int unsigned OP_W    = 2,
  parameter int unsigned META_W  = 8,
  parameter int unsigned TS_W    = 8,
  parameter int unsigned HDM_W   = 16,
  parameter int unsigned CAP_W   = 16,
  parameter int unsigned CREDIT_VEC_W = N_POOLS*AMT_W,
  parameter int unsigned MREQ_W  = COUNT_W+1,
  parameter int unsigned SLOT_W  = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  parameter int unsigned TAG_W   = GEN_W + SLOT_W,
  parameter int unsigned OCC_W   = SLOT_W + 1
) (
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic [TS_W-1:0]            current_ts,

  // ---- configuration request/response ----
  input  logic                       cfg_req_valid,
  output logic                       cfg_req_ready,
  input  logic [HDM_W-1:0]           cfg_hdm_base,
  input  logic [HDM_W-1:0]           cfg_hdm_size,
  input  logic [CAP_W-1:0]           cfg_capacity,
  input  logic                       cfg_timeout_en,
  input  logic [TS_W-1:0]            cfg_timeout_thresh,
  input  logic [N_POOLS*MREQ_W-1:0]  cfg_cmax,
  input  logic [EPOCH_W-1:0]         cfg_epoch,
  output logic                       cfg_rsp_valid,
  input  logic                       cfg_rsp_ready,
  output logic [2:0]                 cfg_rsp_code,
  output logic [2:0]                 cfg_rsp_reason,

  // ---- admission request ----
  input  logic                       req_valid,
  input  logic [OP_W-1:0]            req_op,
  input  logic [META_W-1:0]          req_meta,
  input  logic [CREDIT_VEC_W-1:0]    req_credit_vec,
  output logic                       req_ready,
  output logic                       req_accept,
  output logic [TAG_W-1:0]           issued_tag,

  // ---- issue buffer / downstream ----
  input  logic                       downstream_ready,
  output logic                       issue_valid,
  output logic [TAG_W-1:0]           issue_tag,

  // ---- retirement ----
  input  logic                       resp_valid,
  input  logic [TAG_W-1:0]           resp_tag,
  output logic                       resp_retire,
  output logic [2:0]                 resp_class,
  output logic [EPOCH_W-1:0]         retired_epoch,

  // ---- reclaim ----
  input  logic                       reclaim_req_valid,
  output logic                       reclaim_req_ready,
  input  logic [TAG_W-1:0]           reclaim_tag,
  output logic                       reclaim_rsp_valid,
  input  logic                       reclaim_rsp_ready,
  output logic [TAG_W-1:0]           reclaim_rsp_tag,
  output logic [2:0]                 reclaim_rsp_class,

  // ---- observability ----
  output logic                       global_cfg_commit_fire,
  output logic [EPOCH_W-1:0]         active_epoch,
  output logic                       active_timeout_en,
  output logic [TS_W-1:0]            active_timeout_thresh,
  output logic [HDM_W-1:0]           active_hdm_base,
  output logic [HDM_W-1:0]           active_hdm_size,
  output logic [CAP_W-1:0]           active_capacity,
  output logic [N_POOLS*COUNT_W-1:0] used,
  output logic [N_POOLS*COUNT_W-1:0] available,
  output logic [OCC_W-1:0]           occupancy
);
  // ---- inter-block wiring ----
  logic req_accept_enable, credit_config_commit, credit_frozen_empty;
  logic [N_POOLS*MREQ_W-1:0] committed_max;
  logic tracker_alloc_fire, credit_consume_fire, issue_enqueue;
  logic credit_return_valid, credit_return_accepted;
  logic retire_commit_fire, reclaim_commit_fire;
  logic [OCC_W-1:0] quarantined_count;
  logic credit_cfg_commit_fire, credit_cfg_reject;

  // credit_used == 0 across all pools (drain quiescence term)
  logic credit_used_zero;
  always_comb begin
    credit_used_zero = 1'b1;
    for (int p = 0; p < N_POOLS; p++)
      if (used[p*COUNT_W +: COUNT_W] != '0) credit_used_zero = 1'b0;
  end

  config_ctrl #(.N_POOLS(N_POOLS), .COUNT_W(COUNT_W), .MREQ_W(MREQ_W), .TS_W(TS_W),
                .EPOCH_W(EPOCH_W), .HDM_W(HDM_W), .CAP_W(CAP_W), .OCC_W(OCC_W)) u_cfg (
    .clk(clk), .rst_n(rst_n),
    .cfg_req_valid(cfg_req_valid), .cfg_req_ready(cfg_req_ready),
    .cfg_hdm_base(cfg_hdm_base), .cfg_hdm_size(cfg_hdm_size), .cfg_capacity(cfg_capacity),
    .cfg_timeout_en(cfg_timeout_en), .cfg_timeout_thresh(cfg_timeout_thresh),
    .cfg_cmax(cfg_cmax), .cfg_epoch(cfg_epoch),
    .cfg_rsp_valid(cfg_rsp_valid), .cfg_rsp_ready(cfg_rsp_ready),
    .cfg_rsp_code(cfg_rsp_code), .cfg_rsp_reason(cfg_rsp_reason),
    .adm_occupancy(occupancy), .adm_quarantined(quarantined_count),
    .adm_credit_used_zero(credit_used_zero), .adm_issue_valid(issue_valid),
    .adm_req_accept(req_accept), .adm_retire_commit_fire(retire_commit_fire),
    .adm_reclaim_commit_fire(reclaim_commit_fire),
    .credit_cfg_commit_fire(credit_cfg_commit_fire), .credit_cfg_reject(credit_cfg_reject),
    .req_accept_enable(req_accept_enable), .global_cfg_commit_fire(global_cfg_commit_fire),
    .credit_config_commit(credit_config_commit), .credit_frozen_empty(credit_frozen_empty),
    .committed_max_o(committed_max),
    .active_timeout_en(active_timeout_en), .active_timeout_thresh(active_timeout_thresh),
    .active_epoch(active_epoch), .active_hdm_base(active_hdm_base),
    .active_hdm_size(active_hdm_size), .active_capacity(active_capacity)
  );

  admission_top #(.N_POOLS(N_POOLS), .AMT_W(AMT_W), .COUNT_W(COUNT_W), .RESET_MAX(RESET_MAX),
                  .DEPTH(DEPTH), .GEN_W(GEN_W), .EPOCH_W(EPOCH_W), .OP_W(OP_W),
                  .META_W(META_W), .TS_W(TS_W)) u_adm (
    .clk(clk), .rst_n(rst_n),
    .current_ts(current_ts), .timeout_enable(active_timeout_en), .timeout_thresh(active_timeout_thresh),
    .active_epoch(active_epoch),
    .req_valid(req_valid), .req_accept_enable(req_accept_enable), .req_op(req_op),
    .req_meta(req_meta), .req_credit_vec(req_credit_vec), .req_ready(req_ready),
    .req_accept(req_accept), .issued_tag(issued_tag),
    .downstream_ready(downstream_ready), .issue_valid(issue_valid), .issue_tag(issue_tag),
    .resp_valid(resp_valid), .resp_tag(resp_tag), .resp_retire(resp_retire),
    .resp_class(resp_class), .retired_epoch(retired_epoch),
    .reclaim_req_valid(reclaim_req_valid), .reclaim_req_ready(reclaim_req_ready),
    .reclaim_tag(reclaim_tag), .reclaim_rsp_valid(reclaim_rsp_valid),
    .reclaim_rsp_ready(reclaim_rsp_ready), .reclaim_rsp_tag(reclaim_rsp_tag),
    .reclaim_rsp_class(reclaim_rsp_class),
    .cfg_committed_max(committed_max), .cfg_config_commit(credit_config_commit),
    .cfg_frozen_empty(credit_frozen_empty), .credit_cfg_commit_fire(credit_cfg_commit_fire),
    .credit_cfg_reject(credit_cfg_reject),
    .tracker_alloc_fire(tracker_alloc_fire), .credit_consume_fire(credit_consume_fire),
    .issue_enqueue(issue_enqueue), .credit_return_valid(credit_return_valid),
    .credit_return_accepted(credit_return_accepted), .retire_commit_fire(retire_commit_fire),
    .reclaim_commit_fire(reclaim_commit_fire), .quarantined_count(quarantined_count),
    .used(used), .available(available), .occupancy(occupancy)
  );

`ifdef FORMAL
  logic f_init; initial f_init = 1'b0;
  logic f_prst; always_ff @(posedge clk) begin f_init<=1'b1; f_prst<=rst_n; end
  always @(posedge clk) begin
    if (rst_n && f_init && f_prst) begin
      // ---- SHARED COMMIT: the single global edge IS every consumer's commit ----
      assert (global_cfg_commit_fire == credit_cfg_commit_fire);
      // a local credit-manager rejection on the shared commit is UNREACHABLE
      if (global_cfg_commit_fire) assert (!credit_cfg_reject);
      // no consumer commits without the shared edge
      assert (credit_cfg_commit_fire == global_cfg_commit_fire);
      // (B4/B8) no live entry crosses a commit: occupancy is 0 at the commit edge
      if (global_cfg_commit_fire) assert (occupancy == '0 && quarantined_count == '0);
      // (B5) admission frozen -> no admission side effects while (re)configuring
      if (!req_accept_enable) assert (!req_accept && !tracker_alloc_fire && !credit_consume_fire);
    end
  end
`endif
endmodule
`endif
