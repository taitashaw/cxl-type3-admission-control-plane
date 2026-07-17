// hdm_config.sv
// Registered HDM + TIMEOUT configuration owned behind a DECOUPLED valid/ready
// request/response handshake with a FREEZE -> DRAIN -> atomic COMMIT -> REOPEN
// sequence. Backpressure (cfg_req_ready=0) replaces BUSY pulses: nothing is
// dropped, so no contradictory disposition exists.
//
// The configuration payload is ATOMIC and includes the timeout policy:
//   {HDM windows + device capacity (from shadow), timeout_enable, timeout_thresh}
// all commit on ONE edge together with cfg_epoch. The tracker never mutates its
// own threshold, so a live entry can never observe a threshold change.
//
// COMMIT is gated on: frozen AND outstanding_cnt==0 AND !alloc_fire — so a
// threshold/config change can never land on the same edge as an admission.
//
//   ACTIVE : req_accept_enable=1. On cfg_update_req:
//              - shadow invalid  -> reject immediately (no freeze), stay ACTIVE
//              - shadow valid     -> go to FREEZE
//   FREEZE : traffic_freeze=1, req_accept_enable=0 (no NEW request accepted).
//              wait until outstanding_cnt==0 (in-flight old-epoch traffic drains)
//   COMMIT : still frozen; copy shadow->active atomically, bump epoch, done.
//              -> ACTIVE
//
// The validated shadow is snapshotted into an immutable PENDING copy at accept
// time, and COMMIT writes active from PENDING (not shadow), so later shadow
// writes cannot corrupt the in-flight update. Because active config changes ONLY
// in COMMIT — entered only after admission is frozen and outstanding_cnt reaches
// 0 — the ACTIVE CONFIGURATION REMAINS STABLE UNTIL ADMISSION IS FROZEN AND ALL
// REPORTED OUTSTANDING TRANSACTIONS HAVE DRAINED. (Per-request epoch *capture*
// is an M2 property, once the outstanding tracker stores an epoch per tag; it is
// NOT claimed here.) Reason codes match tb/models/hdm_model.py.
`ifndef HDM_CONFIG_SV
`define HDM_CONFIG_SV

module hdm_config #(
  parameter int unsigned HPA_W = 40,
  parameter int unsigned DPA_W = 32,
  parameter int unsigned N_WIN = 4,
  parameter int unsigned OCNT_W = 16,
  parameter int unsigned TS_W   = 8,
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

  // ---- configuration REQUEST channel (decoupled, backpressured) ----
  input  logic                       cfg_req_valid,
  output logic                       cfg_req_ready,
  input  logic                       cfg_req_timeout_en,      // payload
  input  logic [TS_W-1:0]            cfg_req_timeout_thresh,  // payload
  // ---- configuration RESPONSE channel (decoupled, backpressured) ----
  output logic                       cfg_rsp_valid,
  input  logic                       cfg_rsp_ready,
  output logic [1:0]                 cfg_rsp_code,    // RSP_OK | RSP_INVALID
  output logic [3:0]                 cfg_rsp_reason,

  // ---- datapath status / admission control ----
  input  logic [OCNT_W-1:0]          outstanding_cnt, // from tracker; 0 == drained
  input  logic                       alloc_fire,      // tracker allocation firing THIS cycle
  output logic                       traffic_freeze,
  output logic                       req_accept_enable,
  output logic [15:0]                cfg_epoch,
  output logic [1:0]                 cfg_state,

  // ---- committed timeout configuration (to the tracker) ----
  output logic                       timeout_enable,
  output logic [TS_W-1:0]            timeout_thresh,

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
                         CFG_OVERLAP=8, CFG_TIMEOUT_BAD=9;  // illegal timeout threshold
  localparam logic [1:0] RSP_OK=0, RSP_INVALID=1;

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
  logic              act_to_en;
  logic [TS_W-1:0]   act_to_th;

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
  logic              pend_to_en;
  logic [TS_W-1:0]   pend_to_th;

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
  assign dev_capacity   = act_cap;
  assign timeout_enable = act_to_en;
  assign timeout_thresh = act_to_th;

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

  // timeout payload legality: disabled is always legal; if enabled the threshold
  // must satisfy 0 < t < 2^(TS_W-1) so modulo age is unambiguous.
  logic to_legal;
  assign to_legal = (!cfg_req_timeout_en)
                 || ((cfg_req_timeout_thresh != '0)
                     && (cfg_req_timeout_thresh < (TS_W'(1) << (TS_W-1))));

  // overall request verdict = HDM shadow validity AND timeout payload legality
  logic [3:0] shadow_reason, req_reason;
  logic       req_ok;
  always_comb begin
    if (first_win_reason != CFG_OK) shadow_reason = first_win_reason;
    else if (overlap_bad)           shadow_reason = CFG_OVERLAP;
    else                            shadow_reason = CFG_OK;
    if (shadow_reason != CFG_OK)    req_reason = shadow_reason;
    else if (!to_legal)             req_reason = CFG_TIMEOUT_BAD;
    else                            req_reason = CFG_OK;
    req_ok = (req_reason == CFG_OK);
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
  // Backpressure: not ready while processing an update OR while a response is
  // still unconsumed. At most ONE accepted request is in flight.
  assign cfg_req_ready     = (state == S_ACTIVE) && !cfg_rsp_valid;
  logic req_accept;
  assign req_accept        = cfg_req_valid && cfg_req_ready;

  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // Reset from ANY state: cancels an incomplete request, clears an unconsumed
      // response (no post-reset response for a pre-reset request), and returns the
      // active configuration to documented defaults (all windows disabled,
      // timeouts disabled, epoch 0).
      for (k = 0; k < N_WIN; k++) begin
        sh_en[k]<=1'b0; sh_base[k]<='0; sh_size[k]<='0; sh_dpa[k]<='0;
        act_en[k]<=1'b0; act_base[k]<='0; act_size[k]<='0; act_dpa[k]<='0;
        pend_en[k]<=1'b0; pend_base[k]<='0; pend_size[k]<='0; pend_dpa[k]<='0;
      end
      sh_cap<='0; act_cap<='0; pend_cap<='0;
      pend_to_en<=1'b0; pend_to_th<='0; act_to_en<=1'b0; act_to_th<='0;
      cfg_rsp_valid<=1'b0; cfg_rsp_code<=RSP_OK; cfg_rsp_reason<=CFG_OK;
      cfg_epoch<='0; state<=S_ACTIVE;
    end else begin
      // Shadow writes are always allowed; they never touch the in-flight PENDING
      // snapshot, so a shadow write between accept and commit is harmless.
      if (sh_we) begin
        sh_en[sh_idx]   <= sh_en_i;
        sh_base[sh_idx] <= sh_base_i;
        sh_size[sh_idx] <= sh_size_i;
        sh_dpa[sh_idx]  <= sh_dpa_i;
      end
      if (sh_cap_we) sh_cap <= sh_cap_i;

      // response consumption (contents stay stable while valid && !ready)
      if (cfg_rsp_valid && cfg_rsp_ready) cfg_rsp_valid <= 1'b0;

      unique case (state)
        S_ACTIVE: begin
          if (req_accept) begin
            if (!req_ok) begin
              // INVALID: respond immediately; never freeze, never touch active cfg
              cfg_rsp_valid  <= 1'b1;
              cfg_rsp_code   <= RSP_INVALID;
              cfg_rsp_reason <= req_reason;
            end else begin
              // SNAPSHOT the whole payload exactly once (windows+cap+timeout)
              for (k = 0; k < N_WIN; k++) begin
                pend_en[k]   <= sh_en[k];
                pend_base[k] <= sh_base[k];
                pend_size[k] <= sh_size[k];
                pend_dpa[k]  <= sh_dpa[k];
              end
              pend_cap   <= sh_cap;
              pend_to_en <= cfg_req_timeout_en;
              pend_to_th <= cfg_req_timeout_thresh;
              state      <= S_FREEZE;
            end
          end
        end
        S_FREEZE: begin
          // Commit only once admission is frozen, the datapath is drained AND no
          // allocation fires on this edge -> a config/timeout change can never
          // land on the same edge as an admission.
          if ((outstanding_cnt == '0) && !alloc_fire) state <= S_COMMIT;
        end
        S_COMMIT: begin
          // ATOMIC: windows + capacity + timeout policy + epoch all on ONE edge.
          for (k = 0; k < N_WIN; k++) begin
            act_en[k]   <= pend_en[k];
            act_base[k] <= pend_base[k];
            act_size[k] <= pend_size[k];
            act_dpa[k]  <= pend_dpa[k];
          end
          act_cap        <= pend_cap;
          act_to_en      <= pend_to_en;
          act_to_th      <= pend_to_th;
          cfg_epoch      <= cfg_epoch + 16'd1;
          cfg_rsp_valid  <= 1'b1;
          cfg_rsp_code   <= RSP_OK;
          cfg_rsp_reason <= CFG_OK;
          state          <= S_ACTIVE;
        end
        default: state <= S_ACTIVE;
      endcase
    end
  end

`ifdef FORMAL
  // ---- M2.1 handshake + atomic-commit safety properties ---------------------
  // ENVIRONMENT ASSUMPTION (interface contract, not a DUT guarantee): while
  // cfg_req_valid && !cfg_req_ready the requester holds valid and payload stable.
  // Published in docs/interface_contract.md.
  logic f_init;
  logic [1:0]        f_pstate;
  logic [OCNT_W-1:0] f_pout;
  logic              f_palloc, f_paccept, f_prsp_valid, f_prst_n;
  logic [15:0]       f_pepoch;
  logic              f_pen0, f_ppend0, f_pto_en, f_ppto_en;
  logic [TS_W-1:0]   f_pto_th, f_ppto_th;
  logic [1:0]        f_prsp_code;
  logic [3:0]        f_prsp_reason;
  logic              f_prsp_ready;
  logic [3:0]        f_inflight;      // accepted - completed
  initial f_init = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) f_inflight <= '0;
    else f_inflight <= f_inflight + {3'b0, req_accept} - {3'b0, (cfg_rsp_valid && cfg_rsp_ready)};
  end
  always_ff @(posedge clk) begin
    f_init<=1'b1; f_pstate<=cfg_state; f_pout<=outstanding_cnt; f_palloc<=alloc_fire;
    f_paccept<=req_accept; f_prsp_valid<=cfg_rsp_valid; f_pepoch<=cfg_epoch; f_prst_n<=rst_n;
    f_pen0<=act_en[0]; f_ppend0<=pend_en[0];
    f_pto_en<=act_to_en; f_pto_th<=act_to_th; f_ppto_en<=pend_to_en; f_ppto_th<=pend_to_th;
    f_prsp_code<=cfg_rsp_code; f_prsp_reason<=cfg_rsp_reason; f_prsp_ready<=cfg_rsp_ready;
  end

  always @(posedge clk) begin
    // reset returns protocol accounting to zero and emits no response
    if (f_init && !f_prst_n && rst_n) begin
      assert (f_inflight == '0);
      assert (!cfg_rsp_valid);
      assert (cfg_state == S_ACTIVE);
      assert (cfg_epoch == 16'd0);
      assert (act_en[0] == 1'b0);
      assert (act_to_en == 1'b0);          // documented timeout default: disabled
    end
    if (rst_n && f_init) begin
      // --- strengthening invariants (make the accounting inductive) ---
      // While an update is being processed no response can be pending: accepting
      // required cfg_req_ready = (ACTIVE && !rsp_valid), and rsp_valid is only
      // set on the COMMIT edge (which returns to ACTIVE) or on an INVALID accept.
      if (cfg_state != S_ACTIVE) assert (!cfg_rsp_valid);
      // in-flight accounting is exactly "processing OR unconsumed response"
      assert (f_inflight == ({3'b0, (cfg_state != S_ACTIVE)} + {3'b0, cfg_rsp_valid}));
      // at most one accepted request in flight (accepted - completed in {0,1})
      assert (f_inflight <= 4'd1);
      // ready is low while processing or while a response is unconsumed
      assert (!cfg_req_ready || ((cfg_state == S_ACTIVE) && !cfg_rsp_valid));
      // a newly asserted response comes from an accept (INVALID) or a COMMIT
      if (cfg_rsp_valid && !f_prsp_valid) assert (f_paccept || (f_pstate == S_COMMIT));
      // response is STABLE while backpressured (held until consumed, contents fixed)
      if (f_prsp_valid && !f_prsp_ready) begin
        assert (cfg_rsp_valid);
        assert (cfg_rsp_code   == f_prsp_code);
        assert (cfg_rsp_reason == f_prsp_reason);
      end
      // epoch increments exactly once per successful commit
      assert (cfg_epoch == (f_pepoch + ((f_pstate == S_COMMIT) ? 16'd1 : 16'd0)));
      // active config (incl. timeout policy) changes ONLY on a commit edge
      if (f_pstate != S_COMMIT) begin
        assert (act_en[0]  == f_pen0);
        assert (act_to_en  == f_pto_en);
        assert (act_to_th  == f_pto_th);
      end
      // ...and a commit writes active from the immutable PENDING snapshot
      // (NOT from the shadow, which may have been rewritten after acceptance).
      if (f_pstate == S_COMMIT) begin
        assert (act_en[0]  == f_ppend0);
        assert (act_to_en  == f_ppto_en);
        assert (act_to_th  == f_ppto_th);
      end
      // the pending snapshot is stable while an update is being processed
      if (f_pstate != S_ACTIVE && cfg_state != S_ACTIVE) begin
        assert (pend_en[0] == f_ppend0);
        assert (pend_to_en == f_ppto_en);
        assert (pend_to_th == f_ppto_th);
      end
      // COMMIT is entered only from FREEZE with drained datapath and NO allocation
      if (f_pstate == S_FREEZE && cfg_state == S_COMMIT)
        assert (f_pout == '0 && !f_palloc);
      // commit and allocation are mutually exclusive on the same edge
      if (f_pstate == S_COMMIT) assert (!f_palloc);
    end
    // freeze and admission are mutually exclusive every cycle
    assert (!(traffic_freeze && req_accept_enable));
  end
`endif
endmodule
`endif
