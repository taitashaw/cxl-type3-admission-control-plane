// admission_top.sv
// M4 Phase 2b — atomic admission datapath tying the outstanding_tracker to the
// credit_manager. ONE authoritative admission event drives all allocation-side
// effects together; credits consumed on that edge are returned EXACTLY ONCE via
// the tracker's combinational commit sidebands (retire / reclaim), aggregated
// per pool at RET_W = AMT_W+1 so a same-cycle dual return cannot truncate.
//
// Credit-vector layout (contract): CREDIT_VEC_W = N_POOLS*AMT_W, pool p occupies
// credit_vec[p*AMT_W +: AMT_W]. The tracker stores this vector per entry; the
// credit_manager consumes/returns per pool. Elaboration checks below reject any
// incompatible width.
//
// Scope: shared GLOBAL configuration commit (HDM/cap/timeout/credit-maxima/epoch)
// is DEFERRED to Phase 2c. Here the credit maxima are fixed at RESET_MAX and the
// active config epoch is an input captured on accept; no cfg commit occurs.
`ifndef ADMISSION_TOP_SV
`define ADMISSION_TOP_SV
// outstanding_tracker.sv and credit_manager.sv are provided by the ordered
// filelist (sim/filelists/tb_admission_top.f) — no textual includes.

module admission_top #(
  parameter int unsigned N_POOLS   = 2,
  parameter int unsigned AMT_W     = 3,     // per-pool credit consumed by one request
  parameter int unsigned COUNT_W   = 6,     // credit used/max width (>= AMT_W+1 for headroom)
  parameter int unsigned RESET_MAX = 8,     // per-pool credit maximum (fixed this phase)
  parameter int unsigned DEPTH     = 4,
  parameter int unsigned GEN_W     = 4,
  parameter int unsigned EPOCH_W   = 8,
  parameter int unsigned OP_W      = 2,
  parameter int unsigned META_W    = 8,
  parameter int unsigned TS_W      = 8,
  // derived
  parameter int unsigned CREDIT_VEC_W = N_POOLS*AMT_W,
  parameter int unsigned RET_W        = AMT_W+1,          // dual-return headroom (no truncation)
  parameter int unsigned RETVEC_W     = N_POOLS*RET_W,
  parameter int unsigned SLOT_W       = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  parameter int unsigned TAG_W        = GEN_W + SLOT_W,
  parameter int unsigned OCC_W        = SLOT_W + 1
) (
  input  logic                       clk,
  input  logic                       rst_n,

  // committed timeout config (owned upstream; passed straight to the tracker)
  input  logic [TS_W-1:0]            current_ts,
  input  logic                       timeout_enable,
  input  logic [TS_W-1:0]            timeout_thresh,

  // active configuration epoch (config-stable input; captured on accept)
  input  logic [EPOCH_W-1:0]         active_epoch,

  // ---- admission request (one authoritative accept event) ----
  input  logic                       req_valid,
  input  logic                       req_accept_enable,     // A2 gate (config-stable)
  input  logic [OP_W-1:0]            req_op,
  input  logic [META_W-1:0]          req_meta,
  input  logic [CREDIT_VEC_W-1:0]    req_credit_vec,        // per-pool credits to consume
  output logic                       req_ready,
  output logic                       req_accept,
  output logic [TAG_W-1:0]           issued_tag,

  // ---- issue buffer drain (downstream backpressure) ----
  input  logic                       downstream_ready,
  output logic                       issue_valid,           // a transaction is buffered
  output logic [TAG_W-1:0]           issue_tag,

  // ---- retirement (response) ----
  input  logic                       resp_valid,
  input  logic [TAG_W-1:0]           resp_tag,
  output logic                       resp_retire,
  output logic [2:0]                 resp_class,
  output logic [EPOCH_W-1:0]         retired_epoch,    // captured active_epoch of the retiring entry

  // ---- reclaim (registered handshake) ----
  input  logic                       reclaim_req_valid,
  output logic                       reclaim_req_ready,
  input  logic [TAG_W-1:0]           reclaim_tag,
  output logic                       reclaim_rsp_valid,
  input  logic                       reclaim_rsp_ready,
  output logic [TAG_W-1:0]           reclaim_rsp_tag,
  output logic [2:0]                 reclaim_rsp_class,

  // ---- observability ----
  output logic                       tracker_alloc_fire,
  output logic                       credit_consume_fire,
  output logic                       issue_enqueue,
  output logic                       credit_return_valid,
  output logic                       credit_return_accepted,
  output logic [N_POOLS*COUNT_W-1:0] used,
  output logic [N_POOLS*COUNT_W-1:0] available,
  output logic [OCC_W-1:0]           occupancy
);
  // ---- elaboration width contract ------------------------------------------
  if (COUNT_W < AMT_W + 1) begin : g_count_w_chk
    $error("admission_top: COUNT_W (%0d) must be >= AMT_W+1 (%0d)", COUNT_W, AMT_W+1);
  end
  if (CREDIT_VEC_W != N_POOLS*AMT_W) begin : g_vec_w_chk
    $error("admission_top: CREDIT_VEC_W must equal N_POOLS*AMT_W");
  end

  // ==========================================================================
  // ONE authoritative admission event
  //   req_ready depends ONLY on registered / config-stable conditions:
  //   rst_n, req_accept_enable, tracker allocation readiness (!full, registered),
  //   credit consume readiness (pure function of registered ledger + amount),
  //   and issue-buffer readiness (registered). No downstream *valid* feeds ready.
  // ==========================================================================
  logic tracker_full, credit_consume_ready, issue_ready;
  assign req_ready  = rst_n && req_accept_enable && !tracker_full
                            && credit_consume_ready && issue_ready;
  assign req_accept = req_valid && req_ready;

  // ---- one-entry issue buffer (ready = !full, registered; 1-cycle drain bubble)
  logic           issue_full_r;
  logic [TAG_W-1:0] issue_tag_r;
  assign issue_ready   = !issue_full_r;
  assign issue_enqueue = req_accept;
  assign issue_valid   = issue_full_r;
  assign issue_tag     = issue_tag_r;

  // ==========================================================================
  // Outstanding tracker: allocation driven EXCLUSIVELY by req_accept; the entry
  // stores the active epoch and the exact per-pool credit vector.
  // ==========================================================================
  logic [TAG_W-1:0] alloc_tag;
  logic [SLOT_W-1:0] alloc_slot;
  logic             retire_commit_fire, reclaim_commit_fire;
  logic [CREDIT_VEC_W-1:0] retire_commit_credit_vec, reclaim_commit_credit_vec;
  logic [EPOCH_W-1:0] retire_commit_epoch, reclaim_commit_epoch;
  logic [META_W-1:0]  retire_commit_meta, reclaim_commit_meta;
  logic [OP_W-1:0] retired_op; logic [META_W-1:0] retired_meta;
  logic [OCC_W-1:0]  hwm_unused, quar_unused; logic timeout_any_unused;
  logic [META_W-1:0] reclaim_rsp_meta_unused;
  logic [DEPTH-1:0]              dbg_live;
  logic [DEPTH*CREDIT_VEC_W-1:0] dbg_credit_vec;
  logic [DEPTH*EPOCH_W-1:0]      dbg_epoch;
  logic [31:0] ac_u, rc_u, fc_u, tc_u, rcl_u, is_u, nl_u, sg_u; logic es_u; logic [2:0] efc_u;

  outstanding_tracker #(.DEPTH(DEPTH), .GEN_W(GEN_W), .EPOCH_W(EPOCH_W), .OP_W(OP_W),
                        .META_W(META_W), .TS_W(TS_W), .CREDIT_W(CREDIT_VEC_W)) u_tracker (
    .clk(clk), .rst_n(rst_n),
    .current_ts(current_ts), .timeout_enable(timeout_enable), .timeout_thresh(timeout_thresh),
    .alloc_req(req_accept), .alloc_epoch(active_epoch), .alloc_op(req_op),
    .alloc_meta(req_meta), .alloc_credit_vec(req_credit_vec),
    .alloc_gnt(tracker_alloc_fire), .alloc_tag(alloc_tag), .alloc_slot(alloc_slot),
    .full(tracker_full),
    .resp_valid(resp_valid), .resp_tag(resp_tag), .resp_retire(resp_retire),
    .resp_class(resp_class), .retired_epoch(retired_epoch), .retired_op(retired_op),
    .retired_meta(retired_meta),
    .retire_commit_fire(retire_commit_fire), .retire_commit_credit_vec(retire_commit_credit_vec),
    .retire_commit_epoch(retire_commit_epoch), .retire_commit_meta(retire_commit_meta),
    .reclaim_commit_fire(reclaim_commit_fire), .reclaim_commit_credit_vec(reclaim_commit_credit_vec),
    .reclaim_commit_epoch(reclaim_commit_epoch), .reclaim_commit_meta(reclaim_commit_meta),
    .reclaim_req_valid(reclaim_req_valid), .reclaim_req_ready(reclaim_req_ready),
    .reclaim_tag(reclaim_tag), .reclaim_rsp_valid(reclaim_rsp_valid),
    .reclaim_rsp_ready(reclaim_rsp_ready), .reclaim_rsp_tag(reclaim_rsp_tag),
    .reclaim_rsp_class(reclaim_rsp_class), .reclaim_rsp_meta(reclaim_rsp_meta_unused),
    .occupancy(occupancy), .high_watermark(hwm_unused), .quarantined_count(quar_unused),
    .timeout_any(timeout_any_unused), .alloc_count(ac_u), .retire_count(rc_u),
    .full_count(fc_u), .timeout_count(tc_u), .reclaim_count(rcl_u),
    .invalid_slot_count(is_u), .non_live_count(nl_u), .stale_gen_count(sg_u),
    .err_sticky(es_u), .err_first_class(efc_u),
    .dbg_live(dbg_live), .dbg_credit_vec(dbg_credit_vec), .dbg_epoch(dbg_epoch)
  );
  assign issued_tag = alloc_tag;

  // ==========================================================================
  // Credit return aggregation: per pool, add the retire and reclaim commit
  // vectors at AMT_W+1 (RET_W) BEFORE presenting to the ledger. Different-slot
  // dual commit contributes both; same-slot collision resolves to SUPERSEDED in
  // the tracker (reclaim is a no-op) so only the retirement vector is present.
  // ==========================================================================
  logic [RETVEC_W-1:0] return_vec;
  genvar gp;
  generate
    for (gp = 0; gp < N_POOLS; gp++) begin : g_ret_agg
      logic [AMT_W-1:0] ret_p, rcl_p;
      logic [RET_W-1:0] sum_p;
      assign ret_p = retire_commit_fire  ? retire_commit_credit_vec [gp*AMT_W +: AMT_W] : '0;
      assign rcl_p = reclaim_commit_fire ? reclaim_commit_credit_vec[gp*AMT_W +: AMT_W] : '0;
      assign sum_p = {1'b0, ret_p} + {1'b0, rcl_p};          // AMT_W+1, cannot truncate
      assign return_vec[gp*RET_W +: RET_W] = sum_p;
    end
  endgenerate
  assign credit_return_valid = retire_commit_fire || reclaim_commit_fire;

  // ==========================================================================
  // Credit ledger. consume driven by req_accept (consume_fire == req_accept);
  // return driven by the aggregated commit vector. Config commit is inactive
  // this phase (maxima fixed at RESET_MAX). return legality holds by the credit
  // conservation invariant, so a return is NEVER rejected (proved in formal).
  // ==========================================================================
  logic [N_POOLS*RET_W-1:0]  cm_return_amount;
  logic [N_POOLS*3-1:0]      cfg_reason_u;
  logic cfg_commit_fire_u, cfg_reject_u;
  logic [N_POOLS*COUNT_W-1:0] configured_max_u, hwm_used_u;
  logic [N_POOLS-1:0] pool_full_u, pool_empty_u;
  logic sticky_err_u; logic [2:0] first_err_type_u;
  logic [((N_POOLS<=1)?1:$clog2(N_POOLS))-1:0] first_err_pool_u; logic [AMT_W-1:0] first_err_amt_u;
  logic [31:0] cok_u, cbl_u, rok_u, ril_u, crj_u;
  assign cm_return_amount = return_vec;

  credit_manager #(.N_POOLS(N_POOLS), .COUNT_W(COUNT_W), .AMT_W(AMT_W), .RET_W(RET_W),
                   .DIAG_W(32), .RESET_MAX(RESET_MAX)) u_credit (
    .clk(clk), .rst_n(rst_n),
    .consume_valid(req_accept), .consume_amount(req_credit_vec),
    .consume_ready(credit_consume_ready), .consume_fire(credit_consume_fire),
    .return_valid(credit_return_valid), .return_amount(cm_return_amount),
    .return_accepted(credit_return_accepted),
    .committed_max('0), .config_commit(1'b0), .frozen_and_empty(1'b0),
    .diagnostic_clear(1'b0), .cfg_commit_fire(cfg_commit_fire_u), .cfg_reject(cfg_reject_u),
    .cfg_reason(cfg_reason_u[2:0]),
    .used(used), .available(available), .configured_max(configured_max_u),
    .pool_full(pool_full_u), .pool_empty(pool_empty_u), .hwm_used(hwm_used_u),
    .sticky_err(sticky_err_u), .first_err_type(first_err_type_u),
    .first_err_pool(first_err_pool_u), .first_err_amount(first_err_amt_u),
    .consume_ok_count(cok_u), .consume_blocked_count(cbl_u), .return_ok_count(rok_u),
    .return_illegal_count(ril_u), .cfg_reject_count(crj_u)
  );

  // ---- issue buffer sequential -------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      issue_full_r <= 1'b0; issue_tag_r <= '0;
    end else begin
      if (issue_full_r && downstream_ready) issue_full_r <= 1'b0;   // drain
      if (req_accept) begin issue_full_r <= 1'b1; issue_tag_r <= alloc_tag; end
    end
  end

`ifdef FORMAL
  // -------- integration properties -----------------------------------------
  logic f_init; initial f_init = 1'b0;
  logic f_pacc; logic [SLOT_W-1:0] f_paslot; logic [EPOCH_W-1:0] f_pae;
  always_ff @(posedge clk) begin
    f_init <= 1'b1;
    f_pacc <= req_accept; f_paslot <= alloc_slot; f_pae <= active_epoch;
  end

  // per-pool live credit sum over the tracker's DEBUG PORTS (dbg_live/dbg_credit_vec
  // are real outputs -> no cross-module hierarchical reference). Quarantined
  // entries remain live and stay in the sum.
  //
  // SUM_W is wide enough for the MATHEMATICAL sum of every live entry's per-pool
  // credit (DEPTH * (2^AMT_W-1)) WITHOUT wrap, plus a headroom bit, so the equality
  // below is true equality — never equality modulo 2^COUNT_W. The upper-bits-zero
  // assert then confirms the (non-wrapping) sum actually fits in COUNT_W.
  localparam int unsigned SUM_W =
      ((COUNT_W > (AMT_W + $clog2(DEPTH+1))) ? COUNT_W : (AMT_W + $clog2(DEPTH+1))) + 1;
  logic [SUM_W-1:0] live_sum [N_POOLS];
  logic [SUM_W-1:0] used_ext [N_POOLS];
  always_comb begin
    for (int p = 0; p < N_POOLS; p++) begin
      live_sum[p] = '0;
      for (int s = 0; s < DEPTH; s++)
        if (dbg_live[s])
          live_sum[p] = live_sum[p]
                      + {{(SUM_W-AMT_W){1'b0}}, dbg_credit_vec[s*CREDIT_VEC_W + p*AMT_W +: AMT_W]};
      used_ext[p] = {{(SUM_W-COUNT_W){1'b0}}, used[p*COUNT_W +: COUNT_W]};
    end
  end

  always @(posedge clk) begin
    if (rst_n && f_init) begin
      // (item 2/3/7) ONE authoritative event: all three consumers fire together
      assert (tracker_alloc_fire  == req_accept);
      assert (credit_consume_fire == req_accept);
      assert (issue_enqueue       == req_accept);
      // (item 7) A2 as a DUT theorem
      if (!req_accept_enable) begin
        assert (!req_accept && !tracker_alloc_fire && !credit_consume_fire && !issue_enqueue);
      end
      // (item 8) return is NEVER rejected (conservation makes it always legal)
      if (credit_return_valid) assert (credit_return_accepted);
      // (item 8) EPOCH CAPTURE: one cycle after an accept, the allocated slot holds
      // the PRESENTED active epoch (catches a mis-wired/wrong epoch capture).
      if (f_pacc) assert (dbg_epoch[f_paslot*EPOCH_W +: EPOCH_W] == f_pae);
      // (item 6) CROSS-BLOCK CONSERVATION: ledger used == sum of live entries'
      // stored credit vectors, per pool (quarantined entries remain live). Proved
      // as MATHEMATICAL equality on a non-wrapping SUM_W accumulator, plus:
      //  - the sum's bits above COUNT_W are zero (no hidden excess stored credit);
      //  - the sum never exceeds the pool maximum RESET_MAX.
      for (int p = 0; p < N_POOLS; p++) begin
        assert (live_sum[p] == used_ext[p]);                       // equality, no truncation
        assert (live_sum[p][SUM_W-1:COUNT_W] == '0);               // upper bits zero
        // within the pool maximum: live_sum == used <= configured_max (the ledger's
        // own used<=max is a proven lemma, so this is inductive).
        assert (live_sum[p] <= {{(SUM_W-COUNT_W){1'b0}}, configured_max_u[p*COUNT_W +: COUNT_W]});
      end
    end
  end
`endif
endmodule
`endif
