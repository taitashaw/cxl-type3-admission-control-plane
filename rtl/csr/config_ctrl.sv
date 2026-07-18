// config_ctrl.sv
// M4 Phase 2c — ONE atomic GLOBAL configuration commit. Decoupled request/response
// handshake (M2.1 style). The complete payload (HDM window/capacity, timeout
// policy, per-pool credit maxima in pre-truncation form, config epoch) is snapshot
// EXACTLY ONCE on acceptance into an immutable `pending` register; later requester
// changes cannot affect it. On a valid request: freeze admission, drain to full
// quiescence, then emit ONE global_cfg_commit_fire on which EVERY active field
// updates from the pending snapshot. An invalid request produces one registered
// INVALID response and never freezes or commits.
`ifndef CONFIG_CTRL_SV
`define CONFIG_CTRL_SV
module config_ctrl #(
  parameter int unsigned N_POOLS = 2,
  parameter int unsigned COUNT_W = 6,
  parameter int unsigned MREQ_W  = COUNT_W+1,
  parameter int unsigned TS_W    = 8,
  parameter int unsigned EPOCH_W = 8,
  parameter int unsigned HDM_W   = 16,
  parameter int unsigned CAP_W   = 16,
  parameter int unsigned OCC_W   = 3
) (
  input  logic                       clk,
  input  logic                       rst_n,

  // ---- decoupled configuration request/response ----
  input  logic                       cfg_req_valid,
  output logic                       cfg_req_ready,
  input  logic [HDM_W-1:0]           cfg_hdm_base,
  input  logic [HDM_W-1:0]           cfg_hdm_size,
  input  logic [CAP_W-1:0]           cfg_capacity,
  input  logic                       cfg_timeout_en,
  input  logic [TS_W-1:0]            cfg_timeout_thresh,
  input  logic [N_POOLS*MREQ_W-1:0]  cfg_cmax,          // pre-truncation credit maxima
  input  logic [EPOCH_W-1:0]         cfg_epoch,
  output logic                       cfg_rsp_valid,
  input  logic                       cfg_rsp_ready,
  output logic [2:0]                 cfg_rsp_code,       // RSP_OK / RSP_INVALID
  output logic [2:0]                 cfg_rsp_reason,

  // ---- drain observability (from the admission datapath) ----
  input  logic [OCC_W-1:0]           adm_occupancy,
  input  logic [OCC_W-1:0]           adm_quarantined,
  input  logic                       adm_credit_used_zero, // every pool used==0
  input  logic                       adm_issue_valid,
  input  logic                       adm_req_accept,
  input  logic                       adm_retire_commit_fire,
  input  logic                       adm_reclaim_commit_fire,
  input  logic                       credit_cfg_commit_fire, // from credit_manager
  input  logic                       credit_cfg_reject,

  // ---- control / active configuration outputs ----
  output logic                       req_accept_enable,     // 0 while (re)configuring
  output logic                       global_cfg_commit_fire,
  output logic                       credit_config_commit,  // -> credit_manager config_commit
  output logic                       credit_frozen_empty,   // -> credit_manager frozen_and_empty
  output logic [N_POOLS*MREQ_W-1:0]  committed_max_o,       // -> credit_manager committed_max (PENDING)
  output logic                       active_timeout_en,
  output logic [TS_W-1:0]            active_timeout_thresh,
  output logic [EPOCH_W-1:0]         active_epoch,
  output logic [HDM_W-1:0]           active_hdm_base,
  output logic [HDM_W-1:0]           active_hdm_size,
  output logic [CAP_W-1:0]           active_capacity
);
  localparam logic [2:0] RSP_OK=0, RSP_INVALID=1;
  localparam logic [2:0] RSN_OK=0, RSN_TIMEOUT=1, RSN_CMAX=2, RSN_HDM=3;
  localparam logic [2:0] S_IDLE=0, S_DRAIN=1, S_RSP_OK=2, S_RSP_INV=3;
  localparam logic [TS_W-1:0] TS_HALF = (TS_W'(1) << (TS_W-1));

  logic [2:0] state;

  // ---- immutable pending snapshot (captured once on accept) ----
  logic [HDM_W-1:0]          p_base, p_size;
  logic [CAP_W-1:0]          p_cap;
  logic                      p_to_en;
  logic [TS_W-1:0]           p_to_thr;
  logic [N_POOLS*MREQ_W-1:0] p_cmax;
  logic [EPOCH_W-1:0]        p_epoch;

  // ---- combinational validity of the PRESENTED request ----
  logic [N_POOLS-1:0] cmax_unrep;
  genvar gp;
  generate
    for (gp = 0; gp < N_POOLS; gp++) begin : g_cmax_chk
      // representable iff no bit at/above COUNT_W is set
      assign cmax_unrep[gp] = |cfg_cmax[gp*MREQ_W + COUNT_W +: (MREQ_W-COUNT_W)];
    end
  endgenerate
  logic to_ok, cmax_ok, hdm_ok, req_valid_cfg;
  logic [2:0] req_reason;
  assign to_ok   = !cfg_timeout_en || ((cfg_timeout_thresh != '0) && (cfg_timeout_thresh < TS_HALF));
  assign cmax_ok = ~(|cmax_unrep);
  assign hdm_ok  = (cfg_hdm_size != '0) && (cfg_capacity != '0);
  assign req_valid_cfg = to_ok && cmax_ok && hdm_ok;
  // deterministic first-reason priority: timeout > cmax > hdm
  assign req_reason = !to_ok ? RSN_TIMEOUT : (!cmax_ok ? RSN_CMAX : (!hdm_ok ? RSN_HDM : RSN_OK));

  // ---- accept / quiescence ----
  logic cfg_accept, quiescent;
  assign cfg_req_ready = rst_n && (state == S_IDLE);
  assign cfg_accept    = cfg_req_valid && cfg_req_ready;
  // FULL drain: no live entries, none quarantined, no credit in use, issue buffer
  // empty, and NO admission/return event in flight this cycle.
  assign quiescent = (adm_occupancy == '0) && (adm_quarantined == '0)
                   && adm_credit_used_zero && !adm_issue_valid && !adm_req_accept
                   && !adm_retire_commit_fire && !adm_reclaim_commit_fire;

  // admission is frozen while draining/committing
  assign req_accept_enable = rst_n && (state == S_IDLE);

  // ONE shared commit: in DRAIN, on the first fully-quiescent cycle.
  assign global_cfg_commit_fire = rst_n && (state == S_DRAIN) && quiescent;
  assign credit_config_commit   = global_cfg_commit_fire;   // credit commits on the same edge
  assign credit_frozen_empty    = (state == S_DRAIN) && quiescent;
  // the credit_manager latches its maxima from the PENDING snapshot at the commit
  // edge (its own cmax_r updates then, exactly like every other active field).
  assign committed_max_o        = p_cmax;

  // representability / legality of the PENDING snapshot (used as a strengthening
  // invariant: DRAIN/RSP_OK are only reached after the request was validated).
  logic [N_POOLS-1:0] p_cmax_unrep;
  generate
    for (gp = 0; gp < N_POOLS; gp++) begin : g_pcmax_chk
      assign p_cmax_unrep[gp] = |p_cmax[gp*MREQ_W + COUNT_W +: (MREQ_W-COUNT_W)];
    end
  endgenerate
  logic p_snapshot_valid;
  assign p_snapshot_valid = ~(|p_cmax_unrep)
                          && (!p_to_en || ((p_to_thr != '0) && (p_to_thr < TS_HALF)))
                          && (p_size != '0) && (p_cap != '0);

  assign cfg_rsp_valid  = (state == S_RSP_OK) || (state == S_RSP_INV);
  assign cfg_rsp_code   = (state == S_RSP_INV) ? RSP_INVALID : RSP_OK;

  logic [2:0] rsp_reason_r;
  assign cfg_rsp_reason = rsp_reason_r;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      p_base<='0; p_size<='0; p_cap<='0; p_to_en<=1'b0; p_to_thr<='0; p_cmax<='0; p_epoch<='0;
      rsp_reason_r <= RSN_OK;
      active_timeout_en<=1'b0; active_timeout_thresh<='0; active_epoch<='0;
      active_hdm_base<='0; active_hdm_size<='0; active_capacity<='0;
    end else begin
      case (state)
        S_IDLE: begin
          if (cfg_accept) begin
            // snapshot the COMPLETE payload exactly once
            p_base<=cfg_hdm_base; p_size<=cfg_hdm_size; p_cap<=cfg_capacity;
            p_to_en<=cfg_timeout_en; p_to_thr<=cfg_timeout_thresh; p_cmax<=cfg_cmax; p_epoch<=cfg_epoch;
            rsp_reason_r <= req_reason;
            state <= req_valid_cfg ? S_DRAIN : S_RSP_INV;
          end
        end
        S_DRAIN: begin
          if (quiescent) begin
            // ONE shared commit edge: every active field updates from `pending`
            active_hdm_base <= p_base; active_hdm_size <= p_size; active_capacity <= p_cap;
            active_timeout_en <= p_to_en; active_timeout_thresh <= p_to_thr;
            active_epoch <= p_epoch;
            state <= S_RSP_OK;
          end
        end
        S_RSP_OK, S_RSP_INV: begin
          if (cfg_rsp_ready) state <= S_IDLE;   // response consumed
        end
        default: state <= S_IDLE;
      endcase
    end
  end

`ifdef FORMAL
  logic f_init; initial f_init = 1'b0;
  logic f_prst; logic [2:0] f_pstate;
  logic [EPOCH_W-1:0] f_pactep;
  logic f_pacttoen; logic [TS_W-1:0] f_pacttothr; logic [HDM_W-1:0] f_pactbase, f_pactsize;
  logic [CAP_W-1:0] f_pactcap; logic f_pgcf;
  always_ff @(posedge clk) begin
    f_init<=1'b1; f_prst<=rst_n; f_pstate<=state; f_pgcf<=global_cfg_commit_fire;
    f_pactep<=active_epoch; f_pacttoen<=active_timeout_en;
    f_pacttothr<=active_timeout_thresh; f_pactbase<=active_hdm_base; f_pactsize<=active_hdm_size;
    f_pactcap<=active_capacity;
  end
  always @(posedge clk) begin
    if (rst_n && f_init && f_prst) begin
      // (B1/B2) EVERY active field changes IFF global_cfg_commit_fire, all from the
      // SAME pending snapshot; no partial update.
      if (f_pgcf) begin
        assert (active_hdm_base == $past(p_base));
        assert (active_hdm_size == $past(p_size));
        assert (active_capacity == $past(p_cap));
        assert (active_timeout_en == $past(p_to_en));
        assert (active_timeout_thresh == $past(p_to_thr));
        assert (active_epoch == $past(p_epoch));
      end else begin
        // no field moves without a commit (B1/B3: no partial update)
        assert (active_hdm_base == f_pactbase && active_hdm_size == f_pactsize);
        assert (active_capacity == f_pactcap);
        assert (active_timeout_en == f_pacttoen && active_timeout_thresh == f_pacttothr);
        assert (active_epoch == f_pactep);
      end
      // (B4) commit implies full quiescence
      if (global_cfg_commit_fire)
        assert (adm_occupancy=='0 && adm_quarantined=='0 && adm_credit_used_zero
                && !adm_issue_valid && !adm_req_accept
                && !adm_retire_commit_fire && !adm_reclaim_commit_fire);
      // (freeze) admission enabled ONLY in IDLE
      assert (req_accept_enable == (state == S_IDLE));
      // STRENGTHENING INVARIANT: the valid path (DRAIN/RSP_OK) is only reached
      // after validation, so the pending snapshot is valid. This makes the shared
      // credit commit (representability-gated) coincide with global_cfg_commit_fire.
      if (state == S_DRAIN || state == S_RSP_OK) assert (p_snapshot_valid);
      // OK response only AFTER a commit (S_RSP_OK reached only via S_DRAIN commit)
      if (cfg_rsp_valid && cfg_rsp_code == RSP_OK) assert (state == S_RSP_OK);
      // INVALID response never coincides with a commit/freeze-driven active change
      if (state == S_RSP_INV) assert (!global_cfg_commit_fire);
    end
  end
`endif
endmodule
`endif
