// hdm_config.sv
// Registered HDM window configuration with a real FREEZE -> DRAIN -> atomic
// COMMIT -> REOPEN protocol (not a bare busy-reject gate).
//
//   ACTIVE : req_accept_enable=1. On cfg_update_req:
//              - shadow invalid  -> reject immediately (no freeze), stay ACTIVE
//              - shadow valid     -> go to FREEZE
//   FREEZE : traffic_freeze=1, req_accept_enable=0 (no NEW request accepted).
//              wait until outstanding_cnt==0 (in-flight old-epoch traffic drains)
//   COMMIT : still frozen; copy shadow->active atomically, bump epoch, done.
//              -> ACTIVE
//
// Shadow writes are ignored while an update is in flight (shadow frozen), so the
// config validated at request time is exactly what commits. Because active
// config changes ONLY in COMMIT — entered only after freeze + full drain — no
// accepted request can ever span a configuration change: every accepted request
// captures exactly one epoch. Reason codes match tb/models/hdm_model.py.
`ifndef HDM_CONFIG_SV
`define HDM_CONFIG_SV

module hdm_config #(
  parameter int unsigned HPA_W = 40,
  parameter int unsigned DPA_W = 32,
  parameter int unsigned N_WIN = 4,
  parameter int unsigned OCNT_W = 16,
  parameter int unsigned IDX_W = (N_WIN > 1) ? $clog2(N_WIN) : 1  // derived; do not override
) (
  input  logic                       clk,
  input  logic                       rst_n,

  // Shadow write port (one window per write)
  input  logic                       sh_we,
  input  logic [IDX_W-1:0]           sh_idx,
  input  logic                       sh_en_i,
  input  logic [HPA_W-1:0]           sh_base_i,
  input  logic [HPA_W-1:0]           sh_size_i,
  input  logic [DPA_W-1:0]           sh_dpa_i,
  input  logic                       sh_cap_we,
  input  logic [DPA_W:0]             sh_cap_i,

  // Reconfiguration protocol
  input  logic                       cfg_update_req,  // 1-cycle pulse: begin reconfig
  input  logic [OCNT_W-1:0]          outstanding_cnt, // from tracker; 0 == drained
  output logic                       traffic_freeze,  // level: block new requests
  output logic                       req_accept_enable,// level: request path may accept
  output logic                       cfg_update_done, // pulse: reconfig finished
  output logic                       cfg_ok,          // pulse (with done): success
  output logic                       cfg_reject,      // pulse (with done): refused
  output logic [3:0]                 cfg_reason,      // reason for last attempt
  output logic [15:0]                cfg_epoch,       // increments per successful commit
  output logic [1:0]                 cfg_state,       // FSM state (observability/formal)

  // Active (validated) configuration for the decoder
  output logic [N_WIN-1:0]           win_en,
  output logic [N_WIN-1:0][HPA_W-1:0] win_base,
  output logic [N_WIN-1:0][HPA_W-1:0] win_size,
  output logic [N_WIN-1:0][DPA_W-1:0] win_dpa_base,
  output logic [DPA_W:0]             dev_capacity
);

  // reason codes (match hdm_model.py)
  localparam logic [3:0] CFG_OK=0, CFG_ZERO_SIZE=1, CFG_BASE_ALIGN=2, CFG_SIZE_ALIGN=3,
                         CFG_DPA_ALIGN=4, CFG_HPA_OVF=5, CFG_DPA_OVF=6, CFG_CAP_EXCEED=7,
                         CFG_OVERLAP=8;

  // ---- shadow + active storage (unpacked for portable element writes) -----
  logic              sh_en   [N_WIN];
  logic [HPA_W-1:0]  sh_base [N_WIN];
  logic [HPA_W-1:0]  sh_size [N_WIN];
  logic [DPA_W-1:0]  sh_dpa  [N_WIN];
  logic [DPA_W:0]    sh_cap;

  logic              act_en   [N_WIN];
  logic [HPA_W-1:0]  act_base [N_WIN];
  logic [HPA_W-1:0]  act_size [N_WIN];
  logic [DPA_W-1:0]  act_dpa  [N_WIN];
  logic [DPA_W:0]    act_cap;

  // Immutable PENDING snapshot: shadow is copied here the cycle cfg_update_req is
  // accepted, and COMMIT writes active from PENDING (not shadow). This closes the
  // TOCTOU where a shadow write between accept and commit could commit an
  // unvalidated config. Shadow may be freely rewritten while an update is in
  // flight without affecting the pending update.
  logic              pend_en   [N_WIN];
  logic [HPA_W-1:0]  pend_base [N_WIN];
  logic [HPA_W-1:0]  pend_size [N_WIN];
  logic [DPA_W-1:0]  pend_dpa  [N_WIN];
  logic [DPA_W:0]    pend_cap;

  // pack active -> ports
  genvar gp;
  generate
    for (gp = 0; gp < N_WIN; gp++) begin : g_pack
      assign win_en[gp]       = act_en[gp];
      assign win_base[gp]     = act_base[gp];
      assign win_size[gp]     = act_size[gp];
      assign win_dpa_base[gp] = act_dpa[gp];
    end
  endgenerate
  assign dev_capacity = act_cap;

  // ---- combinational validation of the SHADOW config ----------------------
  // Per-window reason (priority order matches the reference model).
  localparam int unsigned WSUM = ((HPA_W > DPA_W) ? HPA_W : DPA_W) + 1;
  logic [3:0] win_reason [N_WIN];
  genvar gv;
  generate
    for (gv = 0; gv < N_WIN; gv++) begin : g_val
      logic [HPA_W:0]   hsum;   // base+size, guard bit
      logic [WSUM-1:0]  dsum;   // dpa_base+size at FULL width (size can exceed DPA_W)
      assign hsum = {1'b0, sh_base[gv]} + {1'b0, sh_size[gv]};
      assign dsum = {{(WSUM-DPA_W){1'b0}}, sh_dpa[gv]}
                  + {{(WSUM-HPA_W){1'b0}}, sh_size[gv]};
      // Continuous-assign priority chain (constant genvar index -> portable).
      assign win_reason[gv] =
          (!sh_en[gv])                                   ? CFG_OK        :
          (sh_size[gv] == '0)                            ? CFG_ZERO_SIZE :
          (sh_base[gv][5:0] != '0)                       ? CFG_BASE_ALIGN:
          (sh_size[gv][5:0] != '0)                       ? CFG_SIZE_ALIGN:
          (sh_dpa[gv][5:0]  != '0)                       ? CFG_DPA_ALIGN :
          (hsum > {1'b1, {HPA_W{1'b0}}})                             ? CFG_HPA_OVF   :
          (dsum > {{(WSUM-DPA_W-1){1'b0}}, 1'b1, {DPA_W{1'b0}}})      ? CFG_DPA_OVF   :
          (dsum > {{(WSUM-DPA_W-1){1'b0}}, sh_cap})      ? CFG_CAP_EXCEED:
                                                           CFG_OK;
    end
  endgenerate

  // lowest-index enabled window with a nonzero reason
  logic [3:0] first_win_reason;
  always_comb begin
    first_win_reason = CFG_OK;
    for (int i = N_WIN-1; i >= 0; i--)
      if (win_reason[i] != CFG_OK) first_win_reason = win_reason[i];
  end

  // pairwise overlap among enabled shadow windows (constant-index generate)
  logic [N_WIN*N_WIN-1:0] pair_ovl;
  genvar oi, oj;
  generate
    for (oi = 0; oi < N_WIN; oi++) begin : g_oi
      for (oj = 0; oj < N_WIN; oj++) begin : g_oj
        if (oi < oj) begin : g_pair
          wire [HPA_W:0] loi = {1'b0, sh_base[oi]};
          wire [HPA_W:0] loj = {1'b0, sh_base[oj]};
          wire [HPA_W:0] hii = {1'b0, sh_base[oi]} + {1'b0, sh_size[oi]};
          wire [HPA_W:0] hij = {1'b0, sh_base[oj]} + {1'b0, sh_size[oj]};
          assign pair_ovl[oi*N_WIN+oj] = sh_en[oi] && sh_en[oj] && (loi < hij) && (loj < hii);
        end else begin : g_np
          assign pair_ovl[oi*N_WIN+oj] = 1'b0;
        end
      end
    end
  endgenerate
  logic overlap_bad;
  assign overlap_bad = |pair_ovl;

  // overall shadow verdict
  logic [3:0] shadow_reason;
  logic       shadow_valid;
  always_comb begin
    if (first_win_reason != CFG_OK) shadow_reason = first_win_reason;
    else if (overlap_bad)           shadow_reason = CFG_OVERLAP;
    else                            shadow_reason = CFG_OK;
    shadow_valid = (shadow_reason == CFG_OK);
  end

  // ---- FSM: freeze -> drain -> atomic commit -> reopen --------------------
  typedef enum logic [1:0] {S_ACTIVE, S_FREEZE, S_COMMIT} state_e;
  state_e state;

  // freeze/accept are pure functions of state; in ACTIVE the request path may
  // accept (a request accepted the same cycle as cfg_update_req is old-epoch and
  // will be drained before any commit).
  assign traffic_freeze    = (state != S_ACTIVE);
  assign req_accept_enable = (state == S_ACTIVE);
  assign cfg_state         = 2'(state);

  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // Reset from ANY FSM state returns cleanly to ACTIVE with a disabled
      // active config and no partial commit; shadow/pending are cleared.
      for (k = 0; k < N_WIN; k++) begin
        sh_en[k]<=1'b0; sh_base[k]<='0; sh_size[k]<='0; sh_dpa[k]<='0;
        act_en[k]<=1'b0; act_base[k]<='0; act_size[k]<='0; act_dpa[k]<='0;
        pend_en[k]<=1'b0; pend_base[k]<='0; pend_size[k]<='0; pend_dpa[k]<='0;
      end
      sh_cap<='0; act_cap<='0; pend_cap<='0;
      cfg_ok<=1'b0; cfg_reject<=1'b0; cfg_update_done<=1'b0;
      cfg_reason<=CFG_OK; cfg_epoch<='0; state<=S_ACTIVE;
    end else begin
      cfg_ok          <= 1'b0;
      cfg_reject      <= 1'b0;
      cfg_update_done <= 1'b0;

      // Shadow writes are always allowed; they never touch the in-flight PENDING
      // snapshot, so a shadow write between accept and commit is harmless.
      if (sh_we) begin
        sh_en[sh_idx]   <= sh_en_i;
        sh_base[sh_idx] <= sh_base_i;
        sh_size[sh_idx] <= sh_size_i;
        sh_dpa[sh_idx]  <= sh_dpa_i;
      end
      if (sh_cap_we) sh_cap <= sh_cap_i;

      unique case (state)
        S_ACTIVE: begin
          // A second cfg_update_req is only ever acted on in ACTIVE; requests
          // arriving during FREEZE/COMMIT are ignored (software sees freeze).
          if (cfg_update_req) begin
            if (!shadow_valid) begin
              // fast reject: no freeze/drain for an invalid config
              cfg_reject      <= 1'b1;
              cfg_update_done <= 1'b1;
              cfg_reason      <= shadow_reason;
            end else begin
              // SNAPSHOT the validated shadow into pending (immutable hereafter).
              for (k = 0; k < N_WIN; k++) begin
                pend_en[k]   <= sh_en[k];
                pend_base[k] <= sh_base[k];
                pend_size[k] <= sh_size[k];
                pend_dpa[k]  <= sh_dpa[k];
              end
              pend_cap <= sh_cap;
              state    <= S_FREEZE;
            end
          end
        end
        S_FREEZE: begin
          if (outstanding_cnt == '0) state <= S_COMMIT;  // fully drained
        end
        S_COMMIT: begin
          for (k = 0; k < N_WIN; k++) begin
            act_en[k]   <= pend_en[k];
            act_base[k] <= pend_base[k];
            act_size[k] <= pend_size[k];
            act_dpa[k]  <= pend_dpa[k];
          end
          act_cap         <= pend_cap;
          cfg_epoch       <= cfg_epoch + 16'd1;   // 16-bit rolling; wrap is benign
          cfg_ok          <= 1'b1;
          cfg_update_done <= 1'b1;
          cfg_reason      <= CFG_OK;
          state           <= S_ACTIVE;
        end
        default: state <= S_ACTIVE;
      endcase
    end
  end

`ifdef FORMAL
  // ---- Snapshot / atomicity / drain safety properties (internal access) ----
  logic f_init;
  logic [1:0]           f_pstate;
  logic [OCNT_W-1:0]    f_pout;
  logic [15:0]          f_pepoch;
  logic                 f_pen0;      // active window-0 enable, previous cycle
  logic                 f_ppend0;    // pending window-0 enable, previous cycle
  initial f_init = 1'b0;
  always_ff @(posedge clk) begin
    f_init   <= 1'b1;
    f_pstate <= cfg_state;
    f_pout   <= outstanding_cnt;
    f_pepoch <= cfg_epoch;
    f_pen0   <= act_en[0];
    f_ppend0 <= pend_en[0];
  end

  always @(posedge clk) begin
    if (rst_n && f_init) begin
      // epoch increments by exactly one on commit, else unchanged (mod 2^16)
      assert (cfg_epoch == (f_pepoch + (cfg_ok ? 16'd1 : 16'd0)));
      // active config changes ONLY on a successful commit (atomicity)
      if (!cfg_ok) assert (act_en[0] == f_pen0);
      // commit writes active from the PENDING snapshot
      if (cfg_ok) assert (act_en[0] == f_ppend0);
      // pending snapshot is STABLE while an update is in flight (not ACTIVE)
      if (f_pstate != S_ACTIVE && cfg_state != S_ACTIVE)
        assert (pend_en[0] == f_ppend0);
      // cfg_ok only out of COMMIT; FREEZE->COMMIT only when drained
      if (cfg_ok) assert (f_pstate == S_COMMIT);
      if (f_pstate == S_FREEZE && cfg_state == S_COMMIT) assert (f_pout == '0);
    end
    // freeze and admission are mutually exclusive every cycle
    assert (!(traffic_freeze && req_accept_enable));
  end
`endif
endmodule
`endif
